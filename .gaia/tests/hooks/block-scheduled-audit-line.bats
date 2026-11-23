#!/usr/bin/env bats
#
# Suite for .claude/hooks/block-scheduled-audit-line.sh, the PreToolUse guard
# that keeps an audit checkpoint answer out of any prompt or message Claude
# schedules or sends. Every case drives the hook by direct invocation with a
# fixture payload.
#
# SCHEDULED_LINE_BASH selects the interpreter the hook runs under, so the same
# suite proves the hook under stock /bin/bash 3.2.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/block-scheduled-audit-line.bats < /dev/null
#      SCHEDULED_LINE_BASH=/bin/bash .gaia/scripts/bats5.sh .gaia/tests/hooks/block-scheduled-audit-line.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK="$REPO_ROOT/.claude/hooks/block-scheduled-audit-line.sh"
  BASH_BIN="$(command -v "${SCHEDULED_LINE_BASH:-bash}")"
  # shellcheck source=/dev/null
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
}

# payload <tool_name> <tool_input-json> [cwd]: a PreToolUse payload.
payload() {
  jq -cn --arg tool_name "$1" --argjson tool_input "$2" --arg cwd "${3:-/repo}" \
    '{session_id: "s1", transcript_path: "/tmp/transcript.jsonl", cwd: $cwd, hook_event_name: "PreToolUse", tool_name: $tool_name, tool_input: $tool_input}'
}

# send_raw <payload> [PATH]: deliver it to the hook.
send_raw() {
  if [ "$#" -gt 1 ]; then
    run bash -c 'printf %s "$1" | PATH="$3" "$4" "$2"' _ "$1" "$HOOK" "$2" "$BASH_BIN"
  else
    run bash -c 'printf %s "$1" | "$3" "$2"' _ "$1" "$HOOK" "$BASH_BIN"
  fi
}

send() { send_raw "$(payload "$@")"; }

assert_silent_allow() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=protected
@test "a scheduling or sending call whose prompt is a whole audit line is denied, for every line kind and every guarded tool" {
  local row tool_name tool_input
  local rows=(
    'ScheduleWakeup|{"delaySeconds":60,"reason":"r","prompt":"audit-grant 3"}'
    'CronCreate|{"cron":"7 * * * *","prompt":"audit-accept","recurring":false}'
    'CronCreate|{"cron":"7 * * * *","prompt":"  audit-accept-finding 2\n"}'
    'RemoteTrigger|{"action":"create","body":{"name":"n","job_config":{"steps":[{"prompt":"audit-grant 10"}]}}}'
    'SendMessage|{"to":"peer","message":"audit-accept"}'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r tool_name tool_input <<<"$row"
    send "$tool_name" "$tool_input"
    assert_denied_by_json
    grep -qF 'only a human types an audit checkpoint answer' <<<"$output"
    grep -qF 'audit-grant <n>' <<<"$output"
  done
}

@test "a prompt that only mentions a line, a malformed spelling, or no keyword in the tool input is allowed silently" {
  local row tool_name tool_input
  local rows=(
    'CronCreate|{"cron":"7 * * * *","prompt":"when the checkpoint pins, the person types audit-grant 2"}'
    'ScheduleWakeup|{"delaySeconds":60,"reason":"r","prompt":"audit-grant 11"}'
    'SendMessage|{"to":"peer","message":"CHECKPOINT S2 PR #1: waiting on the audit-accept answer"}'
    'ScheduleWakeup|{"delaySeconds":60,"reason":"r","prompt":"<<autonomous-loop-dynamic>>"}'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r tool_name tool_input <<<"$row"
    send "$tool_name" "$tool_input"
    assert_silent_allow
  done
  echo "case: keyword only in cwd"
  send CronCreate '{"cron":"7 * * * *","prompt":"go"}' /work/audit-accept
  assert_silent_allow
}

@test "fail closed: an unparseable payload, a missing grammar library, or jq absent with a keyword in the tool input blocks with exit 2" {
  local lone_hook="$BATS_TEST_TMPDIR/hooks/block-scheduled-audit-line.sh"
  local path_farm="$BATS_TEST_TMPDIR/no-jq-bin" tool
  echo "case: unparseable"
  send_raw '{"tool_name":"CronCreate","tool_input": not json audit-accept'
  assert_blocked_by_exit

  echo "case: grammar library missing"
  mkdir -p "$BATS_TEST_TMPDIR/hooks/lib"
  cp "$HOOK" "$lone_hook"
  cp "$REPO_ROOT/.claude/hooks/lib/jq-availability.sh" "$BATS_TEST_TMPDIR/hooks/lib/"
  run bash -c 'printf %s "$1" | "$3" "$2"' _ "$(payload CronCreate '{"cron":"7 * * * *","prompt":"audit-accept"}')" "$lone_hook" "$BASH_BIN"
  assert_blocked_by_exit
  grep -qF 'audit-loop-state-lib.sh' <<<"$output"

  echo "case: jq absent"
  mkdir -p "$path_farm"
  for tool in dirname tr mktemp rm cat; do
    ln -s "$(command -v "$tool")" "$path_farm/$tool"
  done
  send_raw "$(payload CronCreate '{"cron":"7 * * * *","prompt":"audit-accept"}')" "$path_farm"
  assert_blocked_by_exit
  grep -qF 'jq is not on PATH' <<<"$output"
  echo "case: jq absent, keyword outside the tool input"
  send_raw "$(payload CronCreate '{"cron":"7 * * * *","prompt":"go"}' /work/audit-accept)" "$path_farm"
  [ "$status" -eq 0 ]
}
