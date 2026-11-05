#!/usr/bin/env bash
# Lists the new tests in a working tree that the commit-time RED gate would
# deny: tests with no recorded failing run (RED) at their current content. A
# plan orchestrator runs it after a test-author dispatch and before the
# implementer dispatch, while an honest RED is still possible.
#
# Usage: red-pending.sh --root <tree root>
#
# It runs the gate itself (.claude/hooks/red-verify-commit-check.sh) on a
# synthetic `git commit`, against a temporary copy of the index that holds the
# whole working tree, so every carve-out and the new-at-HEAD rule are the
# gate's own and never a second copy. The gate is a ledger lookup and a signal
# recompute: no test runs and no RED is recorded. The real index is untouched.
#
# Exit 0: nothing pending. Exit 1: one `file<TAB>fullName` line per pending
# test on stdout. Exit 2: usage error, or the gate could not decide (it denied
# naming no test, such as an unusable package registry); its reason goes to
# stderr. A gate that fails open (no node or git) reports nothing pending,
# the same verdict the commit would get.
set -uo pipefail

root=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root="${2:-}"; shift 2 || shift ;;
    *) printf 'red-pending: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$root" ] || { printf 'red-pending: usage: red-pending.sh --root <tree root>\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'red-pending: jq is required\n' >&2; exit 2; }
root=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) \
  || { printf 'red-pending: not a git work tree: %s\n' "$root" >&2; exit 2; }

gate="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)/.claude/hooks/red-verify-commit-check.sh"
[ -f "$gate" ] || { printf 'red-pending: commit gate not found: %s\n' "$gate" >&2; exit 2; }

work_directory=$(mktemp -d) || exit 2
trap 'rm -rf "$work_directory"' EXIT
temporary_index="$work_directory/index"

real_index=$(git -C "$root" rev-parse --git-path index) || exit 2
case "$real_index" in /*) ;; *) real_index="$root/$real_index" ;; esac
if [ -f "$real_index" ]; then
  cp "$real_index" "$temporary_index" || exit 2
fi
GIT_INDEX_FILE="$temporary_index" git -C "$root" add -A >/dev/null 2>&1 \
  || { printf 'red-pending: could not stage the working tree into a temporary index\n' >&2; exit 2; }

payload=$(jq -nc --arg cwd "$root" '{tool_name:"Bash", tool_input:{command:"git commit"}, cwd:$cwd}')
# The gate reads bare `git` and repo-relative helper paths from its working
# directory, as it does when Claude Code runs it from the tree root.
gate_output=$(cd "$root" && printf '%s' "$payload" \
  | GIT_INDEX_FILE="$temporary_index" bash "$gate")

decision=$(printf '%s' "$gate_output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[ "$decision" = deny ] || exit 0
reason=$(printf '%s' "$gate_output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')

# The gate names each offender as a `  • <file> › <fullName>` line of its deny
# reason; red-pending.bats pins that shape. A file path never holds ` › `, so
# the first one splits file from test name.
bullet='  • '
separator=' › '
pending=''
while IFS= read -r line; do
  case "$line" in "$bullet"*"$separator"*) ;; *) continue ;; esac
  line=${line#"$bullet"}
  pending+="${line%%"$separator"*}"$'\t'"${line#*"$separator"}"$'\n'
done <<<"$reason"

if [ -n "$pending" ]; then
  printf '%s' "$pending"
  exit 1
fi
printf '%s\n' "$reason" >&2
exit 2
