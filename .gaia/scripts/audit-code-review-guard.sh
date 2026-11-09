#!/usr/bin/env bash
# The review child's PreToolUse hook. The child's restricted launch ignores the
# project's settings, which also drops block-sensitive-read.sh, so the child's
# generated settings register this wrapper in its place. It adds the one thing
# that hook has no reason to do: a denial log the review record can count, since
# whether a hook-blocked read appears in the result's own denial list is a
# property of Claude Code, not of this repository.
#
#   audit-code-review-guard.sh <denial-log-file>   (hook payload on stdin)
#
# The target is found relative to this script, never relative to the reviewed
# head: a capture reviewing an older commit runs this wrapper from the build
# checkout, and a head without the hook must not turn every read into a denial.
#
# errexit stays off: a wrapper that dies early exits non-zero, which the
# PreToolUse contract reads as a non-blocking error, so the guard would vanish
# with no denial. The hook's output and status otherwise pass through unchanged.

script_path="${BASH_SOURCE[0]}"
[ "$script_path" = "${script_path%/*}" ] && script_path="./$script_path"
target_hook="${script_path%/*}/../../.claude/hooks/block-sensitive-read.sh"
denial_log="${1:-}"
payload="$(cat)"

log_denial() {
  [ -n "$denial_log" ] || return 0
  # The fixed line keeps the count honest when jq is what is missing; the hook's
  # own jq-availability arm is what denied in that case.
  printf '%s' "$payload" | jq -c '{tool: (.tool_name // "unknown"),
      path: (.tool_input.file_path // .tool_input.path // .tool_input.glob // .tool_input.command // null)}' \
    >>"$denial_log" 2>/dev/null \
    || printf '{"tool":"unknown","path":null}\n' >>"$denial_log"
}

if [ ! -f "$target_hook" ]; then
  log_denial
  cat <<'DENY_JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: the review child's read guard cannot find block-sensitive-read.sh, so dotenv and secret paths are not being checked. This denial is fail-closed by design."
  }
}
DENY_JSON
  exit 0
fi

hook_output="$(printf '%s' "$payload" | bash "$target_hook")"
hook_status=$?
[ -z "$hook_output" ] || printf '%s\n' "$hook_output"

# Status 2 is the hook's own fail-loud arm, a blocking error with no JSON.
case "$hook_output" in
  *'"permissionDecision": "deny"'*) log_denial ;;
  *) [ "$hook_status" -ne 2 ] || log_denial ;;
esac
exit "$hook_status"
