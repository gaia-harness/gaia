#!/usr/bin/env bats
# Tests for .gaia/scripts/provision-wait.sh, the bounded wait on a linked
# worktree's background dependency install.
#
# The script reads two files in the worktree's own git directory, so every
# fixture is a real repository with a real linked worktree and the log and pid
# file are written where the install job writes them. A live install job is
# stood in for by a `sleep` process the teardown kills; a dead one by a process
# that has already exited.
#
# Each failing verdict (INSTALL_FAILED, STILL_RUNNING, DEADLINE_PASSED, STOPPED)
# is driven by the state that must produce it, and the wait's two ways of
# ending early are asserted by what they did not spend: DEADLINE_PASSED must
# return without running its attempts, and STILL_RUNNING must return rather than
# block.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md. `run`
# captures status and `$status` is compared with POSIX `[ ]`.

FINISHED_LINE="provision-worktree: provisioning finished"

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  WAIT="$THIS_DIRECTORY/../provision-wait.sh"
  MAIN_REPOSITORY="$BATS_TEST_TMPDIR/main"
  WORKTREE="$BATS_TEST_TMPDIR/linked"
  SLEEPER_PID=""

  git init -q "$MAIN_REPOSITORY"
  git -C "$MAIN_REPOSITORY" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  git -C "$MAIN_REPOSITORY" worktree add -q -b linked-branch "$WORKTREE"

  GIT_DIRECTORY="$(git -C "$WORKTREE" rev-parse --absolute-git-dir)"
  LOG_FILE="$GIT_DIRECTORY/gaia-provision.log"
  PID_FILE="$GIT_DIRECTORY/gaia-provision.pid"
}

teardown() {
  if [ -n "${SLEEPER_PID:-}" ]; then
    kill "$SLEEPER_PID" 2>/dev/null || true
  fi
  return 0
}

# Starts a process that outlives the test body and records its pid as the
# install job's. Its descriptors are closed so bats does not wait on it.
start_live_job() {
  sleep 30 >/dev/null 2>&1 3>&- &
  SLEEPER_PID=$!
  printf '%s\n' "$SLEEPER_PID" >"$PID_FILE"
}

# Records the pid of a process that has already exited.
record_dead_job() {
  true &
  local dead_pid=$!
  wait "$dead_pid"
  printf '%s\n' "$dead_pid" >"$PID_FILE"
}

# Starts the next case from no log, no pid file and no live job.
reset_state() {
  if [ -n "${SLEEPER_PID:-}" ]; then
    kill "$SLEEPER_PID" 2>/dev/null || true
    SLEEPER_PID=""
  fi
  rm -f "$LOG_FILE" "$PID_FILE"
}

# expect_verdict <label> <status> <verdict> [wait args]: the wait exits with the
# status and prints the verdict on its first line.
expect_verdict() {
  local label="$1" expected_status="$2" verdict="$3"
  shift 3
  run bash "$WAIT" --tree "$WORKTREE" "$@"
  [ "$status" -eq "$expected_status" ] || { echo "$label: status $status"; return 1; }
  [ "${lines[0]}" = "$verdict" ] || { echo "$label: got '${lines[0]}'"; return 1; }
}

expect_log_line() {
  [ "${lines[1]}" = "Log: $LOG_FILE" ] || { echo "$1: log line '${lines[1]}'"; return 1; }
}

@test "each log and pid state exits its verdict code" {
  local started

  printf 'installing\n%s\n' "$FINISHED_LINE" >"$LOG_FILE"
  expect_verdict "finished line" 0 FINISHED || return 1
  expect_log_line "finished line" || return 1

  reset_state
  printf '%s\n\n\n' "$FINISHED_LINE" >"$LOG_FILE"
  expect_verdict "trailing blank lines" 0 FINISHED || return 1

  reset_state
  printf 'provision-worktree: INSTALL FAILED for linked\n%s\n' "$FINISHED_LINE" >"$LOG_FILE"
  expect_verdict "install failed" 3 INSTALL_FAILED || return 1
  expect_log_line "install failed" || return 1

  reset_state
  printf 'installing\n' >"$LOG_FILE"
  start_live_job
  started=$SECONDS
  expect_verdict "live pid, attempts spent" 4 STILL_RUNNING --attempts 2 --interval 0 || return 1
  expect_log_line "live pid, attempts spent" || return 1
  [ $((SECONDS - started)) -lt 10 ] || { echo "live pid, attempts spent: blocked"; return 1; }

  reset_state
  printf 'installing\n' >"$LOG_FILE"
  start_live_job
  touch -t 202001010000 "$PID_FILE"
  started=$SECONDS
  expect_verdict "live pid past the bound" 5 DEADLINE_PASSED --bound 60 --attempts 5 --interval 30 || return 1
  [ $((SECONDS - started)) -lt 10 ] || { echo "live pid past the bound: spent its attempts"; return 1; }

  reset_state
  printf 'installing\n' >"$LOG_FILE"
  record_dead_job
  expect_verdict "dead pid" 6 STOPPED --attempts 2 --interval 0 || return 1
  expect_log_line "dead pid" || return 1

  reset_state
  printf 'installing\n' >"$LOG_FILE"
  expect_verdict "no pid file" 6 STOPPED --attempts 2 --interval 0 || return 1

  reset_state
  printf 'installing\n' >"$LOG_FILE"
  record_dead_job
  touch -t 202001010000 "$PID_FILE"
  expect_verdict "dead pid past the bound" 6 STOPPED --bound 60 --attempts 2 --interval 0 || return 1

  reset_state
  [ ! -e "$LOG_FILE" ]
  expect_verdict "no log file" 0 FINISHED || return 1
  expect_log_line "no log file"
}

@test "the finished line appearing between two attempts exits 0" {
  printf 'installing\n' >"$LOG_FILE"
  start_live_job
  ( sleep 1; printf '%s\n' "$FINISHED_LINE" >>"$LOG_FILE" ) >/dev/null 2>&1 3>&- &
  run bash "$WAIT" --tree "$WORKTREE" --attempts 5 --interval 1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "FINISHED" ]
}

@test "a path that is not a git work tree exits 2" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run bash "$WAIT" --tree "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 2 ]
}
