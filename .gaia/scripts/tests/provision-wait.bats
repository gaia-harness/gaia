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

@test "a log ending in the finished line exits 0 FINISHED with the log path on line 2" {
  printf 'installing\n%s\n' "$FINISHED_LINE" >"$LOG_FILE"
  run bash "$WAIT" --tree "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "FINISHED" ]
  [ "${lines[1]}" = "Log: $LOG_FILE" ]
}

@test "a trailing blank line after the finished line still reads as finished" {
  printf '%s\n\n\n' "$FINISHED_LINE" >"$LOG_FILE"
  run bash "$WAIT" --tree "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "FINISHED" ]
}

@test "an INSTALL FAILED line plus the finished line exits 3 INSTALL_FAILED" {
  printf 'provision-worktree: INSTALL FAILED for linked\n%s\n' "$FINISHED_LINE" >"$LOG_FILE"
  run bash "$WAIT" --tree "$WORKTREE"
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = "INSTALL_FAILED" ]
  [ "${lines[1]}" = "Log: $LOG_FILE" ]
}

@test "no finished line and a live pid exits 4 STILL_RUNNING once the attempts are spent" {
  printf 'installing\n' >"$LOG_FILE"
  start_live_job
  run bash "$WAIT" --tree "$WORKTREE" --attempts 2 --interval 0
  [ "$status" -eq 4 ]
  [ "${lines[0]}" = "STILL_RUNNING" ]
  [ "${lines[1]}" = "Log: $LOG_FILE" ]
}

@test "a live pid started before the bound exits 5 DEADLINE_PASSED without spending its attempts" {
  printf 'installing\n' >"$LOG_FILE"
  start_live_job
  touch -t 202001010000 "$PID_FILE"
  local started=$SECONDS
  run bash "$WAIT" --tree "$WORKTREE" --bound 60 --attempts 5 --interval 30
  [ "$status" -eq 5 ]
  [ "${lines[0]}" = "DEADLINE_PASSED" ]
  [ $((SECONDS - started)) -lt 10 ]
}

@test "a recorded pid that is dead exits 6 STOPPED" {
  printf 'installing\n' >"$LOG_FILE"
  record_dead_job
  run bash "$WAIT" --tree "$WORKTREE" --attempts 2 --interval 0
  [ "$status" -eq 6 ]
  [ "${lines[0]}" = "STOPPED" ]
  [ "${lines[1]}" = "Log: $LOG_FILE" ]
}

@test "a log with no finished line and no pid file exits 6 STOPPED" {
  printf 'installing\n' >"$LOG_FILE"
  run bash "$WAIT" --tree "$WORKTREE" --attempts 2 --interval 0
  [ "$status" -eq 6 ]
  [ "${lines[0]}" = "STOPPED" ]
}

@test "a dead pid past the bound reads STOPPED, not DEADLINE_PASSED" {
  printf 'installing\n' >"$LOG_FILE"
  record_dead_job
  touch -t 202001010000 "$PID_FILE"
  run bash "$WAIT" --tree "$WORKTREE" --bound 60 --attempts 2 --interval 0
  [ "$status" -eq 6 ]
  [ "${lines[0]}" = "STOPPED" ]
}

@test "the finished line appearing between two attempts exits 0" {
  printf 'installing\n' >"$LOG_FILE"
  start_live_job
  ( sleep 1; printf '%s\n' "$FINISHED_LINE" >>"$LOG_FILE" ) >/dev/null 2>&1 3>&- &
  run bash "$WAIT" --tree "$WORKTREE" --attempts 5 --interval 1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "FINISHED" ]
}

@test "no log file exits 0 FINISHED" {
  [ ! -e "$LOG_FILE" ]
  run bash "$WAIT" --tree "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "FINISHED" ]
  [ "${lines[1]}" = "Log: $LOG_FILE" ]
}

@test "a run with a live pid and an interval of zero returns 4 rather than blocking" {
  printf 'installing\n' >"$LOG_FILE"
  start_live_job
  local started=$SECONDS
  run bash "$WAIT" --tree "$WORKTREE" --attempts 3 --interval 0
  [ "$status" -eq 4 ]
  [ $((SECONDS - started)) -lt 10 ]
}

@test "no --tree exits 2" {
  run bash "$WAIT"
  [ "$status" -eq 2 ]
}

@test "a relative --tree exits 2" {
  run bash "$WAIT" --tree relative/path
  [ "$status" -eq 2 ]
}

@test "a non-integer --bound exits 2" {
  run bash "$WAIT" --tree "$WORKTREE" --bound ten
  [ "$status" -eq 2 ]
}

@test "a non-integer --attempts and a non-integer --interval exit 2" {
  run bash "$WAIT" --tree "$WORKTREE" --attempts 1.5
  [ "$status" -eq 2 ]
  run bash "$WAIT" --tree "$WORKTREE" --interval -1
  [ "$status" -eq 2 ]
}

@test "a path that is not a git work tree exits 2" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run bash "$WAIT" --tree "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 2 ]
}
