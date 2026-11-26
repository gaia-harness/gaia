#!/usr/bin/env bash
# The PR review gate: the verdict, the section and the report of a pull
# request's review record, and the writer of the PR body's `## PR review`
# section. The decision itself is .claude/hooks/lib/pr-review-verdict.sh.
#
#   pr-review-gate.sh check   --root <R> --pr <N> [--out-of-scope]
#   pr-review-gate.sh section --run-folder <D>
#   pr-review-gate.sh report  --run-folder <D>
#   pr-review-gate.sh publish --root <R> --pr <N> [--body-in <file> --body-out <file>] [--branch <name>]
#
# check: exit 0 when the review is complete; exit 1 printing `PR review: <reason>.`
# (no trailing period after the commit list); exit 2 when the root, `gh` or the
# pull request cannot be read, never a pass. Every `gh` call runs in a subshell
# at --root, so the repository never comes from the caller's directory.
#
# publish rewrites the section between its markers, or appends it after one blank
# line, and keeps every byte outside the markers. The body travels through
# `gh pr view` and `gh pr edit --body-file`, never a command line; the offline
# pair --body-in/--body-out (both or neither) replaces both gh calls, and then
# the record's branch is --branch, else the current branch of --root.
#
# Exit: 0 done, 1 refusal (a record or marker problem), 2 usage or unreadable input.
# Bash 3.2 compatible.
set -u

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../.claude/hooks/lib/pr-review-verdict.sh
. "$script_directory/../../.claude/hooks/lib/pr-review-verdict.sh" || {
  printf 'pr-review-gate: cannot load .claude/hooks/lib/pr-review-verdict.sh\n' >&2
  exit 2
}
# shellcheck source=main-root-lib.sh
. "$script_directory/main-root-lib.sh" || {
  printf 'pr-review-gate: cannot load main-root-lib.sh\n' >&2
  exit 2
}

usage() {
  printf 'usage: pr-review-gate.sh check|section|report|publish (see the header)\n' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
action="$1"
shift
root="" pr="" run_folder="" body_in="" body_out="" branch="" out_of_scope=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-of-scope)
      out_of_scope=1
      shift
      ;;
    --root | --pr | --run-folder | --body-in | --body-out | --branch)
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --root) root="$2" ;;
        --pr) pr="$2" ;;
        --run-folder) run_folder="$2" ;;
        --body-in) body_in="$2" ;;
        --body-out) body_out="$2" ;;
        --branch) branch="$2" ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done
case "$pr" in
  *[!0-9]*) usage ;;
esac
command -v jq >/dev/null 2>&1 || {
  printf 'pr-review-gate: jq is required\n' >&2
  exit 2
}

read_run_folder_record() {
  local record_file="$run_folder/pr-review.json"
  [ -n "$run_folder" ] || usage
  if [ ! -f "$record_file" ]; then
    printf 'pr-review-gate: no review record at %s\n' "$record_file" >&2
    exit 1
  fi
  cat "$record_file"
}

case "$action" in
  section)
    pr_review_render_section "$(read_run_folder_record)"
    exit $?
    ;;
  report)
    pr_review_render_report "$(read_run_folder_record)"
    exit $?
    ;;
  check | publish) ;;
  *) usage ;;
esac

[ -n "$root" ] && [ -n "$pr" ] || usage
main_root="$(gaia_resolve_main_root "$root" 2>/dev/null)" || {
  printf 'pr-review-gate: cannot resolve the main checkout root for %s\n' "$root" >&2
  exit 2
}

if [ "$action" = publish ] && { [ -n "$body_in" ] || [ -n "$body_out" ]; }; then
  [ -n "$body_in" ] && [ -n "$body_out" ] || usage
  [ -f "$body_in" ] || {
    printf 'pr-review-gate: --body-in file not found: %s\n' "$body_in" >&2
    exit 2
  }
  [ -n "$branch" ] || branch="$(git -C "$root" branch --show-current 2>/dev/null)"
  pr_view_json=""
else
  pr_view_json="$( (cd "$root" && gh pr view "$pr" --json headRefName,headRefOid,baseRefName,body) 2>/dev/null)" || pr_view_json=""
  if ! printf '%s' "$pr_view_json" | jq -e '.headRefName and .headRefOid' >/dev/null 2>&1; then
    printf 'pr-review-gate: gh could not read PR #%s\n' "$pr" >&2
    exit 2
  fi
  branch="$(printf '%s' "$pr_view_json" | jq -r '.headRefName')"
fi

record_path="$(pr_review_record_path "$main_root" "$branch")" || {
  printf 'pr-review-gate: cannot derive the review record path for branch %s\n' "$branch" >&2
  exit 2
}
record=""
[ ! -f "$record_path" ] || record="$(cat "$record_path")"

if [ "$action" = check ]; then
  head_sha="$(printf '%s' "$pr_view_json" | jq -r '.headRefOid')"
  body="$(printf '%s' "$pr_view_json" | jq -r '.body // ""')"
  base_name="$(printf '%s' "$pr_view_json" | jq -r '.baseRefName // ""')"
  base_tip=""
  [ -z "$base_name" ] || base_tip="$(git -C "$root" rev-parse --verify -q "refs/remotes/origin/$base_name" 2>/dev/null)" || base_tip=""
  if reason="$(pr_review_verdict "$record" "$pr" "$body" "$out_of_scope" "$root" "$head_sha" "$base_tip")"; then
    exit 0
  fi
  case "$reason" in
    "commits after the review"*) printf 'PR review: %s\n' "$reason" ;;
    *) printf 'PR review: %s.\n' "$reason" ;;
  esac
  exit 1
fi

# publish
if [ -z "$record" ]; then
  printf 'pr-review-gate: no review record to publish for PR #%s\n' "$pr" >&2
  exit 1
fi
work="$(mktemp -d)" || exit 2
trap 'rm -rf "$work"' EXIT
if [ -z "$pr_view_json" ]; then
  cp "$body_in" "$work/body.md"
else
  printf '%s' "$pr_view_json" | jq -j '.body // ""' >"$work/body.md"
fi

read -r start_count end_count start_line end_line fenced alone <<EOF
$(pr_review_marker_scan "$work/body.md")
EOF
if [ "$fenced" -gt 0 ]; then
  printf 'pr-review-gate: refusing: a PR review marker sits inside a fenced code block\n' >&2
  exit 1
fi
if [ "$alone" -gt 0 ]; then
  printf 'pr-review-gate: refusing: a PR review marker is not alone on its line\n' >&2
  exit 1
fi
if [ "$start_count" -gt 1 ] || [ "$end_count" -gt 1 ]; then
  printf 'pr-review-gate: refusing: duplicate PR review markers\n' >&2
  exit 1
fi
if [ "$start_count" -ne "$end_count" ]; then
  printf 'pr-review-gate: refusing: unbalanced PR review markers\n' >&2
  exit 1
fi
if [ "$start_count" -eq 1 ] && [ "$end_line" -lt "$start_line" ]; then
  printf 'pr-review-gate: refusing: the PR review end marker comes before the start marker\n' >&2
  exit 1
fi

pr_review_render_section "$record" >"$work/section.md" || exit 1

# head/tail keep the outside bytes exactly. BSD head rejects `-n 0`, so a
# section starting on line 1 skips head.
if [ "$start_count" -eq 1 ]; then
  {
    [ "$start_line" -le 1 ] || head -n "$((start_line - 1))" "$work/body.md"
    cat "$work/section.md"
    tail -n "+$((end_line + 1))" "$work/body.md"
  } >"$work/body.new"
else
  {
    if [ -s "$work/body.md" ]; then
      cat "$work/body.md"
      if [ "$(tail -c 1 "$work/body.md" | od -An -tx1 | tr -d ' \n')" = "0a" ]; then
        printf '\n'
      else
        printf '\n\n'
      fi
    fi
    cat "$work/section.md"
  } >"$work/body.new"
fi

if [ -n "$body_out" ]; then
  cat "$work/body.new" >"$body_out" || {
    printf 'pr-review-gate: could not write %s\n' "$body_out" >&2
    exit 1
  }
  exit 0
fi
if cmp -s "$work/body.md" "$work/body.new"; then
  exit 0
fi
(cd "$root" && gh pr edit "$pr" --body-file "$work/body.new" >/dev/null 2>&1) || {
  printf 'pr-review-gate: gh could not write the PR body of #%s\n' "$pr" >&2
  exit 2
}
exit 0
