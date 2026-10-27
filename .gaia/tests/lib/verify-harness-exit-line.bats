#!/usr/bin/env bats
#
# Tests for the terminal `verify-harness exit <status>` line .gaia/tests/verify-harness.sh
# writes on every exit path. A backgrounded run's waiter (the audit loop unit's
# Monitor until-loop) keys on that line, so it must be the last line of the
# output, carry the runner's real exit status, and appear on the early exits
# and on INT/TERM as well as on the normal path. A run that never writes it
# (SIGKILL) leaves the waiter to time out, which reads as a failed verification.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/verify-harness-exit-line.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/lib/helpers/verify-harness-fixture.sh"
  vhf_init || return 1
  PATH="$VHF_SHIM:$PATH"
  cd "$VHF_ROOT" || return 1
}

# last_line_is <status>: the output's final line is the exit line for <status>,
# and no other line is an exit line.
last_line_is() {
  local expected="verify-harness exit $1" last_line exit_line_count
  last_line="$(printf '%s\n' "$output" | tail -n 1)"
  exit_line_count="$(printf '%s\n' "$output" | grep -c '^verify-harness exit ')"
  [ "$last_line" = "$expected" ] && [ "$exit_line_count" -eq 1 ] && return 0
  printf 'expected the last line to be [%s] and the only exit line, got [%s] (%s exit lines)\n--- output ---\n%s\n' \
    "$expected" "$last_line" "$exit_line_count" "$output" >&2
  return 1
}

@test "a passing run ends with the exit line for status 0" {
  run bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" round
  [ "$status" -eq 0 ]
  last_line_is 0
}

@test "a failing run ends with the exit line for status 1" {
  vhf_control 01-files-present 'FAIL  01-files-present.sh: a missing path'
  vhf_commit "a manifest failure"
  run bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" branch
  [ "$status" -eq 1 ]
  last_line_is 1
}

@test "a usage error ends with the exit line for status 2" {
  run bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" bogus
  [ "$status" -eq 2 ]
  last_line_is 2
}

@test "a refused branch run ends with the exit line for status 3" {
  printf 'dirty\n' >src/x-input.txt
  run bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" branch
  [ "$status" -eq 3 ]
  last_line_is 3
}

# interrupt_mid_check <signal> <expected status>: start a round run whose first
# check blocks, signal the runner while that check runs, then end the check so
# bash can act on the pending signal.
interrupt_mid_check() {
  local signal="$1" expected_status="$2" ready_file="$BATS_TEST_TMPDIR/check-ready"
  local log_file="$BATS_TEST_TMPDIR/runner.log" runner_pid check_pid waited=0
  printf '#!/usr/bin/env bash\nprintf "%%s" "$$" >"%s"\nexec sleep 30\n' "$ready_file" >.gaia/tests/shell-lint.sh
  printf 'touch\n' >>.claude/rules/s2-rule.md
  # A non-interactive shell starts a background job with SIGINT ignored, a
  # parallel bats run may hand the test an ignored SIGINT already, and bash
  # cannot trap a signal ignored at entry; perl resets it to the default first.
  perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!\n"' \
    bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" round </dev/null >"$log_file" 2>&1 &
  runner_pid=$!
  while [ ! -s "$ready_file" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready_file" ] || { kill -KILL "$runner_pid" 2>/dev/null; printf 'the blocking check never started\n' >&2; return 1; }
  check_pid="$(cat "$ready_file")"
  kill "-$signal" "$runner_pid"
  kill -TERM "$check_pid"
  status=0
  wait "$runner_pid" || status=$?
  output="$(cat "$log_file")"
  [ "$status" -eq "$expected_status" ] || { printf 'runner exited %s, expected %s\n--- output ---\n%s\n' "$status" "$expected_status" "$output" >&2; return 1; }
  last_line_is "$expected_status"
}

@test "an interrupted run ends with the exit line for status 130" {
  interrupt_mid_check INT 130
}

@test "a terminated run ends with the exit line for status 143" {
  interrupt_mid_check TERM 143
}
