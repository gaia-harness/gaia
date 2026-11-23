#!/usr/bin/env bash
# shellcheck shell=bash
# Markdown backticks in printf formats are literal, not expansions.
# shellcheck disable=SC2016
#
# autonomy-park.sh: the park procedure an unattended run uses to stop,
# resumably, where it needs a human.
#
#   autonomy-park.sh --reason <code> [--pr <n>] [--detail <text>] [--root <path>]
#
# Reason codes, and what each requires, are defined once in
# .gaia/autonomy-park-reasons.json; a code it does not list is refused. It
# parks the working tree named by --root; without --root, the checkout that
# holds this script, never the shell's working directory, so an invocation by
# absolute path parks that tree from any cwd. In order, it:
#
#   1. saves resumable state: a `## Parked` section in the run folder's
#      STATE.md (.gaia/local/runs/<branch key>/), replacing any earlier one
#   2. pushes the branch to origin
#   3. comments on the PR, when there is one, with the reason, the detail and
#      how to resume; an `audit-checkpoint` comment carries the typed grant
#      line, read from `audit-loop-eval.sh brief`
#   4. writes the parked marker (the data file's `marker_file`) in the run
#      folder: {schema, reason, branch, pr, head, parked_at}
#   5. prints one line telling Claude what to do next
#
# Every input is checked before step 1, and a marker left by an earlier park
# is removed then, so a park that fails partway never leaves a parked marker.
# The --detail text, the one caller-supplied part of the comment, is scanned
# with machine-local-ref-lib.sh and refused on a hit.
#
# Exit: 0 parked; 1 a step failed, with one stderr line naming it (push
# refused, gh unauthenticated); 2 usage error or refused input. A failed park
# is reported, never retried.
#
# The script reads no autonomy setting: its callers decide when to park.

set -u

PARK_SCRIPT_DIRECTORY="${BASH_SOURCE[0]%/*}"
[ "$PARK_SCRIPT_DIRECTORY" = "${BASH_SOURCE[0]}" ] && PARK_SCRIPT_DIRECTORY="."
PARK_REASONS_FILE="$PARK_SCRIPT_DIRECTORY/../autonomy-park-reasons.json"
PARK_DETAIL_MAX_BYTES=2000

park_fail() {
  printf 'autonomy-park: %s\n' "$1" >&2
  exit "${2:-1}"
}

park_usage() {
  printf 'usage: autonomy-park.sh --reason <code> [--pr <n>] [--detail <text>] [--root <path>]\n' >&2
  exit 2
}

# shellcheck source=/dev/null
. "$PARK_SCRIPT_DIRECTORY/main-root-lib.sh" || park_fail "cannot load main-root-lib.sh" 2
# shellcheck source=/dev/null
. "$PARK_SCRIPT_DIRECTORY/branch-name-lib.sh" || park_fail "cannot load branch-name-lib.sh" 2
# shellcheck source=/dev/null
. "$PARK_SCRIPT_DIRECTORY/usage-lib.sh" || park_fail "cannot load usage-lib.sh" 2

reason="" pr="" detail="" detail_given=0 root_argument=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason) [ "$#" -ge 2 ] || park_usage; reason="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || park_usage; pr="$2"; shift 2 ;;
    --detail) [ "$#" -ge 2 ] || park_usage; detail="$2"; detail_given=1; shift 2 ;;
    --root) [ "$#" -ge 2 ] || park_usage; root_argument="$2"; shift 2 ;;
    *) park_usage ;;
  esac
done
[ -n "$reason" ] || park_usage

command -v jq >/dev/null 2>&1 || park_fail "jq is required and was not found on PATH" 2
command -v git >/dev/null 2>&1 || park_fail "git is required and was not found on PATH" 2

[ -f "$PARK_REASONS_FILE" ] || park_fail "reason codes file missing: $PARK_REASONS_FILE" 2
reason_entry="$(jq -ce --arg code "$reason" '
  select(.schema == 1 and (.marker_file | type == "string" and test("^[A-Za-z0-9._-]+$")))
  | .reasons[$code] // empty
  | select((.summary | type == "string") and (.resume | type == "string")
      and (.requires_pr | type == "boolean") and (.grant_line | type == "boolean")
      and (.requires_detail | type == "boolean"))' "$PARK_REASONS_FILE" 2>/dev/null)" ||
  park_fail "unknown reason code '$reason' (known: $(jq -r '.reasons | keys | join(", ")' "$PARK_REASONS_FILE" 2>/dev/null))" 2
marker_name="$(jq -r '.marker_file' "$PARK_REASONS_FILE")"
summary="$(printf '%s' "$reason_entry" | jq -r '.summary')"
resume="$(printf '%s' "$reason_entry" | jq -r '.resume')"

if [ -n "$pr" ]; then
  [[ "$pr" =~ ^[1-9][0-9]{0,8}$ ]] || park_fail "--pr must be a pull request number, got '$pr'" 2
elif [ "$(printf '%s' "$reason_entry" | jq -r '.requires_pr')" = true ]; then
  park_fail "reason '$reason' needs --pr <n>" 2
fi
if [ "$(printf '%s' "$reason_entry" | jq -r '.requires_detail')" = true ] && [ -z "$detail" ]; then
  park_fail "reason '$reason' needs --detail <text>" 2
fi
[ "$detail_given" = 0 ] || [ -n "$detail" ] || park_fail "--detail is empty" 2
[ "${#detail}" -le "$PARK_DETAIL_MAX_BYTES" ] || park_fail "--detail is longer than $PARK_DETAIL_MAX_BYTES characters" 2

if [ -z "$root_argument" ]; then
  root_argument="$(cd "$PARK_SCRIPT_DIRECTORY/../.." 2>/dev/null && pwd -P)" ||
    park_fail "cannot resolve the checkout that holds this script" 2
fi
[ -d "$root_argument" ] || park_fail "--root is not a directory: $root_argument" 2
tree_root="$(gaia_resolve_tree_root "$root_argument")" || park_fail "not inside a git working tree: $root_argument" 2
main_root="$(gaia_resolve_main_root "$tree_root" 2>/dev/null)" || park_fail "cannot resolve the main checkout" 2
branch="$(git -C "$tree_root" branch --show-current 2>/dev/null)" || branch=""
[ -n "$branch" ] || park_fail "HEAD is detached: there is no branch to park" 2
[ "$branch" != "$(gaia_usage_default_branch "$tree_root")" ] ||
  park_fail "on the default branch '$branch': there is no work branch to park" 2
branch_key="$(gaia_branch_normalize "$branch")"
[[ "$branch_key" =~ ^[A-Za-z0-9._/-]{1,128}$ ]] || park_fail "branch '$branch' cannot name a run folder" 2
case "$branch_key" in *..* | *//* | /* | */) park_fail "branch '$branch' cannot name a run folder" 2 ;; esac
head_sha="$(git -C "$tree_root" rev-parse HEAD 2>/dev/null)" || park_fail "cannot read HEAD" 2

grant_line=""
if [ "$(printf '%s' "$reason_entry" | jq -r '.grant_line')" = true ]; then
  grant_line="$(bash "$PARK_SCRIPT_DIRECTORY/audit-loop-eval.sh" brief --root "$tree_root" 2>/dev/null |
    jq -r '.grant_line // empty' 2>/dev/null)"
  [[ "$grant_line" =~ ^audit-grant\ [0-9]+$ ]] ||
    park_fail "no grant line: audit-loop-eval.sh brief returned none for '$branch'" 2
fi

run_directory="$main_root/.gaia/local/runs/$branch_key"
state_file="$run_directory/STATE.md"
marker_file="$run_directory/$marker_name"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/autonomy-park.XXXXXX")" || park_fail "cannot create a temporary directory"
trap 'rm -rf "$scratch"' EXIT

comment_file="$scratch/comment.md"
if [ -n "$pr" ]; then
  {
    printf '<!-- gaia:autonomy-park -->\n'
    printf '**Parked: %s.** An unattended run stopped on branch `%s` and needs you.\n' "$summary" "$branch"
    [ -z "$detail" ] || printf '\n%s\n' "$detail"
    printf '\n%s\n' "$resume"
    [ -z "$grant_line" ] || printf '\n```\n%s\n```\n' "$grant_line"
  } > "$comment_file"
  if [ -n "$detail" ]; then
    printf '%s\n' "$detail" > "$scratch/detail.txt"
    if ! hits="$(bash "$PARK_SCRIPT_DIRECTORY/machine-local-ref-lib.sh" text "$scratch/detail.txt" 2>&1)"; then
      park_fail "--detail names a machine-local reference ($(printf '%s' "$hits" | head -n 1)); reword --detail" 2
    fi
  fi
fi

mkdir -p "$run_directory" || park_fail "cannot create the run folder $run_directory"
rm -f "$marker_file" || park_fail "cannot remove the earlier parked marker $marker_file"
{
  if [ -f "$state_file" ]; then
    awk '/^## Parked$/ { skip = 1; next } skip && /^## / { skip = 0 } !skip' "$state_file"
  else
    printf '# State\n'
  fi
  printf '\n## Parked\n\n'
  printf -- '- Reason: %s (%s)\n' "$reason" "$summary"
  printf -- '- PR: %s\n' "${pr:+#$pr}"
  printf -- '- Head: %s\n' "$head_sha"
  [ -z "$detail" ] || printf -- '- Detail: %s\n' "$(printf '%s' "$detail" | tr '\n' ' ')"
  printf -- '- Resume: %s\n' "$resume"
  [ -z "$grant_line" ] || printf -- '- Grant line: `%s`\n' "$grant_line"
} > "$scratch/STATE.md" || park_fail "cannot write the run state"
mv -f "$scratch/STATE.md" "$state_file" || park_fail "cannot save $state_file"

if ! push_output="$(git -C "$tree_root" push -u origin "$branch" 2>&1)"; then
  park_fail "push refused: $(printf '%s' "$push_output" | tail -n 1)"
fi

if [ -n "$pr" ]; then
  command -v gh >/dev/null 2>&1 || park_fail "gh is required to comment on PR #$pr and was not found on PATH"
  if ! gh_output="$(cd "$tree_root" && gh pr comment "$pr" --body-file "$comment_file" 2>&1)"; then
    park_fail "gh pr comment on PR #$pr failed: $(printf '%s' "$gh_output" | tail -n 1)"
  fi
fi

jq -n --arg reason "$reason" --arg branch "$branch" --arg pr "$pr" --arg head "$head_sha" \
  --arg parked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schema: 1, reason: $reason, branch: $branch, pr: (if $pr == "" then null else ($pr | tonumber) end),
    head: $head, parked_at: $parked_at}' > "$scratch/marker.json" || park_fail "cannot write the parked marker"
mv -f "$scratch/marker.json" "$marker_file" || park_fail "cannot save the parked marker $marker_file"

printf 'Parked %s on %s%s. Next: send a PushNotification if that tool is available, then end this iteration and schedule no work on this item.\n' \
  "$reason" "$branch" "${pr:+ (PR #$pr)}"
