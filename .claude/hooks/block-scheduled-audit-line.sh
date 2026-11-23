#!/usr/bin/env bash
# shellcheck shell=bash
#
# PreToolUse hook (ScheduleWakeup|CronCreate|RemoteTrigger|SendMessage): deny a
# call that would carry an audit checkpoint answer in a prompt Claude authored.
#
# audit-loop-grant.sh records a grant or accept when a whole submitted prompt is
# an audit line. Claude Code fires UserPromptSubmit for a prompt this session
# scheduled for itself too (a CronCreate job, a ScheduleWakeup iteration), and
# that payload carries no documented field telling it from a typed prompt, so
# the recorder cannot refuse it on arrival. This guard stops it at the source:
# a call whose tool_input holds any string that is, whole, an audit line under
# gaia_loop_parse_line (audit-loop-state-lib.sh owns the grammar) is denied. A
# string that only mentions a line parses as malformed and is allowed, the same
# split the recorder makes.
#
# Every string in tool_input is read, not one named field, so a prompt nested in
# a RemoteTrigger body reaches the check. SendMessage is covered because a sent
# message arrives at the receiving session as a prompt; its delivery wrapper
# keeps that prompt from being the bare line today (audit-loop-grant.bats pins
# it), and this guard still holds if the wrapper changes.
#
# Fail closed: an unreadable payload, a missing library, or jq absent while the
# tool input names a keyword exits 2. A payload naming neither keyword exits 0
# before any jq call. Bash 3.2; never `cd`s outside the command substitution
# that locates the libraries.

set -uo pipefail

payload=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' payload || true
fi

case "$payload" in
  *audit-grant* | *audit-accept*) ;;
  *) exit 0 ;;
esac

_scheduled_line_hook_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _scheduled_line_hook_directory=''
# shellcheck source=/dev/null
[ -n "$_scheduled_line_hook_directory" ] && [ -f "$_scheduled_line_hook_directory/lib/jq-availability.sh" ] &&
  . "$_scheduled_line_hook_directory/lib/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-scheduled-audit-line.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the scheduled audit line guard' "$payload" tool_input 'audit-grant' 'audit-accept'

_scheduled_line_state_library="$_scheduled_line_hook_directory/../../.gaia/scripts/audit-loop-state-lib.sh"
# shellcheck source=/dev/null
[ -n "$_scheduled_line_hook_directory" ] && [ -f "$_scheduled_line_state_library" ] &&
  . "$_scheduled_line_state_library" 2>/dev/null
if ! type gaia_loop_parse_line >/dev/null 2>&1; then
  printf 'BLOCKED: block-scheduled-audit-line.sh cannot load .gaia/scripts/audit-loop-state-lib.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi

# Each keyword-bearing string leaf of tool_input, NUL-terminated. A NUL inside a
# value splits it, which can only turn up a shorter string: the deny direction.
leaves_file="$(mktemp "${TMPDIR:-/tmp}/scheduled-audit-line.XXXXXX")" || {
  printf 'BLOCKED: block-scheduled-audit-line.sh could not create a scratch file, so this call cannot be checked.\n' >&2
  exit 2
}
trap 'rm -f "$leaves_file"' EXIT
if ! printf '%s' "$payload" |
  jq -j 'if type == "object" then (.tool_input // {}) | .. | strings | select(test("audit-(grant|accept)")) | . + "\u0000" else error("not an object") end' \
    >"$leaves_file" 2>/dev/null; then
  printf 'BLOCKED: block-scheduled-audit-line.sh could not parse the tool payload, so this call cannot be checked.\n' >&2
  exit 2
fi

found=""
while IFS= read -r -d '' leaf; do
  case "$(gaia_loop_parse_line "$leaf")" in
    "grant "* | accept | "accept-finding "*)
      found=1
      break
      ;;
  esac
done <"$leaves_file"
[ -n "$found" ] || exit 0

grant_line="$(gaia_loop_grant_line 1)"
reason="BLOCKED: only a human types an audit checkpoint answer (${grant_line% 1} <n>, $(gaia_loop_accept_line), audit-accept-finding <n>). A prompt or message Claude schedules or sends never carries one, because it would reach the grant recorder as if typed. Claude: do not retry by another tool or spelling; ask the person at the checkpoint."
jq -n --arg reason "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
exit 0
