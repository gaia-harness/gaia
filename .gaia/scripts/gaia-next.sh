#!/usr/bin/env bash
# shellcheck shell=bash
#
# gaia-next.sh: the job picker behind /gaia-next (.claude/commands/gaia-next.md).
# It reads state and changes none. The queue's rules: wiki/concepts/GAIA Next.md.
#
#   gaia-next.sh pick [--root <path>]
#   gaia-next.sh debt --backlog <file> --report <file> [--root <path>]
#   gaia-next.sh comments --pr <n> [--root <path>]
#
# --root names the checkout to read, default the one holding the working
# directory; plans and run folders are read from its main checkout.
#
# pick walks the first three tiers in order and prints one JSON object:
#   {"job":"plan","plan_dir":<abs>,"branch":<b>,...}  a plan whose RUNNING sentinel stands
#   {"job":"pr","pr":<n>,"branch":<b>,...}            an open PR you authored whose branch is local
#   {"job":"spec","spec":<id>,...}                     the first draft spec
#   {"job":"backlog",...}                              none: read the debt backlog, then run `debt`
# debt takes the ordered backlog (the ordering command in
# .claude/skills/gaia/references/debt.md) and debt-backlog.sh's report on it,
# and prints {"job":"debt","issue":<n>,...} for the first candidate it does not
# skip, else {"job":"none",...}.
# Every object carries "skipped": [{"item","reason"}], and each skip is also
# printed to stderr as `gaia-next: skipped <item>: <reason>`. A plan or pr job
# whose branch holds a parked marker carries "parked": <its reason code>.
#
# Skips apply under autonomy (autonomy_active in autonomy-lib.sh) only; the
# skip rules are in wiki/concepts/GAIA Next.md (## Skips under autonomy).
#
# comments prints
#   {"pr":<n>,"comments":[{kind,author,permission,created_at,url,body}],
#    "withheld":[{author,permission,count}]}
# over the PR's conversation comments, review comments and review bodies,
# oldest first. permission is the author's repository permission
# (`gh api repos/{owner}/{repo}/collaborators/<login>/permission`), `none` when
# the lookup fails. Under autonomy a comment whose author's permission is not
# admin or write is withheld: counted by author, its body never printed.
#
# Exit: 0 an answer; 1 a read failed (git, gh, the notebook, an input file),
# with one stderr line; 2 usage, a library that will not load, or a --root
# outside a git working tree.

set -u

NEXT_SCRIPT_DIRECTORY="${BASH_SOURCE[0]%/*}"
[ "$NEXT_SCRIPT_DIRECTORY" = "${BASH_SOURCE[0]}" ] && NEXT_SCRIPT_DIRECTORY="."
NEXT_PARK_REASONS_FILE="${GAIA_NEXT_PARK_REASONS_FILE:-$NEXT_SCRIPT_DIRECTORY/../autonomy-park-reasons.json}"

next_fail() {
  printf 'gaia-next: %s\n' "$1" >&2
  exit "${2:-1}"
}

next_usage() {
  printf 'usage: gaia-next.sh pick [--root <path>]\n       gaia-next.sh debt --backlog <file> --report <file> [--root <path>]\n       gaia-next.sh comments --pr <n> [--root <path>]\n' >&2
  exit 2
}

# shellcheck source=/dev/null
. "$NEXT_SCRIPT_DIRECTORY/autonomy-lib.sh" || next_fail "cannot load autonomy-lib.sh" 2
# shellcheck source=/dev/null
. "$NEXT_SCRIPT_DIRECTORY/branch-name-lib.sh" || next_fail "cannot load branch-name-lib.sh" 2
# shellcheck source=/dev/null
. "$NEXT_SCRIPT_DIRECTORY/notebook/notebook-lib.sh" || next_fail "cannot load notebook-lib.sh" 2

verb="${1:-}"
[ "$#" -gt 0 ] && shift
root_argument="" backlog_file="" report_file="" pr=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || next_usage; root_argument="$2"; shift 2 ;;
    --backlog) [ "$#" -ge 2 ] || next_usage; backlog_file="$2"; shift 2 ;;
    --report) [ "$#" -ge 2 ] || next_usage; report_file="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || next_usage; pr="$2"; shift 2 ;;
    *) next_usage ;;
  esac
done
case "$verb" in
  pick) [ -z "$backlog_file$report_file$pr" ] || next_usage ;;
  debt) [ -n "$backlog_file" ] && [ -n "$report_file" ] && [ -z "$pr" ] || next_usage ;;
  comments) [[ "$pr" =~ ^[1-9][0-9]{0,8}$ ]] && [ -z "$backlog_file$report_file" ] || next_usage ;;
  *) next_usage ;;
esac

command -v jq >/dev/null 2>&1 || next_fail "jq is required and was not found on PATH"
command -v git >/dev/null 2>&1 || next_fail "git is required and was not found on PATH"
tree_root="$(gaia_resolve_tree_root "${root_argument:-$PWD}")" ||
  next_fail "not inside a git working tree: ${root_argument:-$PWD}" 2
main_root="$(gaia_resolve_main_root "$tree_root" 2>/dev/null)" || next_fail "cannot resolve the main checkout"
# The notebook library resolves its main checkout from this tree.
export GAIA_NOTEBOOK_TREE="$tree_root"

autonomous=0
autonomy_active "$tree_root" && autonomous=1

SKIPPED=""
skip() {
  printf 'gaia-next: skipped %s: %s\n' "$1" "$2" >&2
  SKIPPED="$SKIPPED$(jq -cn --arg item "$1" --arg reason "$2" '{item: $item, reason: $reason}')"$'\n'
}

answer() {
  printf '%s' "$SKIPPED" | jq -cs --argjson job "$1" '$job + {skipped: .}'
  exit 0
}

PROTECTED_GLOBS="" PROTECTED_READ=0
# protected_path_named <file>...: prints the first path the files name that is
# in the protected set, or `the protected set (unreadable)` when the set cannot
# be read. Returns 1 when they name none.
protected_path_named() {
  local token
  if [ "$PROTECTED_READ" = 0 ]; then
    PROTECTED_GLOBS="$(autonomy_protected_globs "$tree_root" 2>/dev/null)" || PROTECTED_GLOBS=""
    PROTECTED_READ=1
  fi
  if [ -z "$PROTECTED_GLOBS" ]; then
    printf 'the protected set (unreadable)\n'
    return 0
  fi
  # A named path is a run of path characters holding a `/`, or a bare
  # CLAUDE.md or CLAUDE.local.md; a leading ./ and trailing dots are dropped.
  while IFS= read -r token; do
    token="${token#./}"
    while [ "${token%.}" != "$token" ]; do token="${token%.}"; done
    [ -n "$token" ] || continue
    if autonomy_protected_match "$token" "$PROTECTED_GLOBS"; then
      printf '%s\n' "$token"
      return 0
    fi
  done < <(cat -- "$@" 2>/dev/null | grep -oE '[A-Za-z0-9._@+*-]*(/[A-Za-z0-9._@+*-]+)+/?|CLAUDE(\.local)?\.md')
  return 1
}

# read_park_marker_name runs at the top level of pick, never inside $( ... ), so
# a failed read exits the script instead of only a subshell.
PARK_MARKER_NAME=""
read_park_marker_name() {
  PARK_MARKER_NAME="$(jq -r '.marker_file // empty' "$NEXT_PARK_REASONS_FILE" 2>/dev/null)"
  [[ "$PARK_MARKER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || next_fail "cannot read the parked marker name from $NEXT_PARK_REASONS_FILE"
}

# parked_reason <branch>: prints the reason code of the branch's parked marker
# and returns 0 while the marker stands; returns 1 when there is none or a new
# commit on the branch released it.
parked_reason() {
  local branch="$1" key marker marker_head reason branch_head
  key="$(gaia_branch_normalize "$branch")"
  marker="$main_root/.gaia/local/runs/$key/$PARK_MARKER_NAME"
  [ -e "$marker" ] || return 1
  # An unreadable marker still stands: only a readable head can release it.
  reason="$(jq -r '.reason // empty' "$marker" 2>/dev/null)" || reason=""
  marker_head="$(jq -r '.head // empty' "$marker" 2>/dev/null)" || marker_head=""
  branch_head="$(git -C "$tree_root" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)" || branch_head=""
  if [ -n "$marker_head" ] && [ -n "$branch_head" ] && [ "$marker_head" != "$branch_head" ]; then
    return 1
  fi
  printf '%s\n' "${reason:-unreadable marker}"
}

# running_plans: prints `<plan directory>\t<branch>` for each plan folder whose
# RUNNING sentinel stands, spec-less plans first, each group sorted.
running_plans() {
  local kind_directory name plan_directory branch
  kind_directory="$(gaia_notebook_kind_directory plan)" || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    plan_directory="$kind_directory/$name"
    [ -f "$plan_directory/RUNNING" ] || continue
    branch="$(sed -n 's/^branch:[[:space:]]*//p' "$plan_directory/RUNNING" | head -n 1)"
    printf '%s\t%s\n' "$plan_directory" "$branch"
  done < <(gaia_notebook_folders plan) || return 1
  kind_directory="$(gaia_notebook_kind_directory spec)" || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    for plan_directory in "$kind_directory/$name"/plan*; do
      [[ "${plan_directory##*/}" =~ $_GAIA_NOTEBOOK_SPEC_PLAN_PATTERN ]] || continue
      [ -d "$plan_directory" ] && [ ! -L "$plan_directory" ] && [ -f "$plan_directory/RUNNING" ] || continue
      branch="$(sed -n 's/^branch:[[:space:]]*//p' "$plan_directory/RUNNING" | head -n 1)"
      printf '%s\t%s\n' "$plan_directory" "$branch"
    done
  done < <(gaia_notebook_folders spec) || return 1
}

pick() {
  local plans plan_directory branch reason hit plan_branches="" prs number spec item
  read_park_marker_name
  plans="$(running_plans)" || next_fail "cannot list the notebook's plan folders"
  while IFS=$'\t' read -r plan_directory branch; do
    [ -n "$plan_directory" ] || continue
    plan_branches="$plan_branches$branch"$'\n'
    item="plan ${plan_directory#"$main_root/"}"
    if [ "$autonomous" = 1 ]; then
      if [ -z "$branch" ]; then
        skip "$item" "its RUNNING sentinel names no branch"
        continue
      fi
      if ! git -C "$tree_root" show-ref --verify --quiet "refs/heads/$branch"; then
        skip "$item" "its branch $branch is not in this clone"
        continue
      fi
    fi
    reason="$( [ -z "$branch" ] || parked_reason "$branch")" || reason=""
    if [ "$autonomous" = 1 ] && [ -n "$reason" ]; then
      skip "$item" "parked ($reason)"
      continue
    fi
    if [ "$autonomous" = 1 ] && hit="$(protected_path_named "$plan_directory"/task-*.md)"; then
      skip "$item" "names $hit in the protected set"
      continue
    fi
    answer "$(jq -cn --arg plan_dir "$plan_directory" --arg branch "$branch" --arg parked "$reason" \
      '{job: "plan", plan_dir: $plan_dir, branch: $branch} + (if $parked == "" then {} else {parked: $parked} end)')"
  done <<<"$plans"

  command -v gh >/dev/null 2>&1 || next_fail "gh is required and was not found on PATH"
  prs="$(cd "$tree_root" && gh pr list --author @me --state open --limit 200 --json number,headRefName \
    --jq 'sort_by(.number) | .[] | "\(.number)\t\(.headRefName)"' 2>/dev/null)" ||
    next_fail "gh pr list failed"
  while IFS=$'\t' read -r number branch; do
    [ -n "$number" ] || continue
    git -C "$tree_root" show-ref --verify --quiet "refs/heads/$branch" || continue
    printf '%s' "$plan_branches" | grep -qxF -- "$branch" && continue
    reason="$(parked_reason "$branch")" || reason=""
    if [ "$autonomous" = 1 ] && [ -n "$reason" ]; then
      skip "pr #$number" "parked ($reason)"
      continue
    fi
    answer "$(jq -cn --argjson pr "$number" --arg branch "$branch" --arg parked "$reason" \
      '{job: "pr", pr: $pr, branch: $branch} + (if $parked == "" then {} else {parked: $parked} end)')"
  done <<<"$prs"

  # The allocator's stderr (its refusal reason, or the one-time notebook move
  # command) is left unsilenced so it reaches the operator. Under autonomy the
  # spec tier is skipped anyway, so a failure there does not end the pick before
  # the backlog tier.
  if ! spec="$(bash "$NEXT_SCRIPT_DIRECTORY/spec/spec-allocator.sh" in_progress "$main_root")"; then
    [ "$autonomous" = 1 ] || next_fail "spec-allocator.sh in_progress failed"
    skip "the draft-spec tier" "spec-allocator.sh in_progress failed"
    spec=""
  fi
  if [ -n "$spec" ] && [ "$spec" != none ]; then
    if [ "$autonomous" = 1 ]; then
      skip "spec $spec" "a draft spec is interactive only"
    else
      answer "$(jq -cn --arg spec "$spec" '{job: "spec", spec: $spec}')"
    fi
  fi
  answer '{"job":"backlog"}'
}

debt() {
  local candidates number body_file hit
  if ! jq -e 'type == "array"' "$backlog_file" >/dev/null 2>&1; then
    next_fail "--backlog is not a readable JSON array: $backlog_file"
  fi
  candidates="$(jq -r '.candidates | if type == "array" then .[] else error end' "$report_file" 2>/dev/null)" ||
    next_fail "--report has no candidates array: $report_file"
  body_file="$(mktemp "${TMPDIR:-/tmp}/gaia-next.XXXXXX")" || next_fail "cannot create a temporary file"
  trap 'rm -f "$body_file"' EXIT
  while IFS= read -r number; do
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
    if [ "$autonomous" = 1 ]; then
      jq -r --argjson number "$number" 'map(select(.number == $number)) | .[0].body // ""' "$backlog_file" > "$body_file" ||
        next_fail "cannot read issue #$number from --backlog"
      if hit="$(protected_path_named "$body_file")"; then
        skip "issue #$number" "names $hit in the protected set"
        continue
      fi
    fi
    answer "$(jq -cn --argjson issue "$number" '{job: "debt", issue: $issue}')"
  done <<<"$candidates"
  answer '{"job":"none"}'
}

comments() {
  local raw logins login permission permissions='{}'
  command -v gh >/dev/null 2>&1 || next_fail "gh is required and was not found on PATH"
  raw="$(
    cd "$tree_root" || exit 1
    gh api --paginate "repos/{owner}/{repo}/issues/$pr/comments" \
      --jq '.[] | {kind: "comment", author: .user.login, created_at, url: .html_url, body}' || exit 1
    gh api --paginate "repos/{owner}/{repo}/pulls/$pr/comments" \
      --jq '.[] | {kind: "review-comment", author: .user.login, created_at, url: .html_url, body}' || exit 1
    gh api --paginate "repos/{owner}/{repo}/pulls/$pr/reviews" \
      --jq '.[] | select((.body // "") != "") | {kind: "review", author: .user.login, created_at: .submitted_at, url: .html_url, body}' || exit 1
  )" || next_fail "cannot read the comments on PR #$pr"
  raw="$(printf '%s\n' "$raw" | jq -cs 'sort_by(.created_at)')" || next_fail "the comments on PR #$pr are not JSON"
  logins="$(printf '%s' "$raw" | jq -r '[.[].author | select(type == "string")] | unique | .[]')"
  while IFS= read -r login; do
    [ -n "$login" ] || continue
    permission="$(cd "$tree_root" && gh api "repos/{owner}/{repo}/collaborators/$login/permission" --jq '.permission' 2>/dev/null)" ||
      permission=""
    [ -n "$permission" ] || permission=none
    permissions="$(jq -cn --argjson map "$permissions" --arg login "$login" --arg permission "$permission" '$map + {($login): $permission}')"
  done <<<"$logins"
  printf '%s' "$raw" | jq -c --argjson pr "$pr" --argjson permissions "$permissions" --argjson autonomous "$autonomous" '
    map(. + {permission: ($permissions[.author // ""] // "none")})
    | (if $autonomous == 1 then map(select(.permission == "admin" or .permission == "write")) else . end) as $kept
    | {pr: $pr, comments: $kept,
       withheld: (if $autonomous == 1
         then map(select(.permission != "admin" and .permission != "write"))
           | group_by(.author) | map({author: .[0].author, permission: .[0].permission, count: length})
         else [] end)}'
}

case "$verb" in
  pick) pick ;;
  debt) debt ;;
  comments) comments ;;
esac
