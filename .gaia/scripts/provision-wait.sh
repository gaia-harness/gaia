#!/usr/bin/env bash
# shellcheck shell=bash
#
# provision-wait.sh: wait for a fresh linked worktree's background dependency
# install to finish, so a run's first `pnpm` step does not race it. Run it by
# any path that resolves; the spelling below assumes a shell at the checkout root:
#   bash .gaia/scripts/provision-wait.sh --tree <absolute worktree path>
#                                        [--bound <seconds>] [--attempts <n>]
#                                        [--interval <seconds>]
#
# Line 1 of stdout is the verdict token, line 2 is `Log: <absolute log path>`.
# One exit code per verdict, so a caller branches on the status:
#   0   FINISHED         the log ends in the finished line with no INSTALL FAILED
#                        line, or no log exists (provisioning ran inline in the
#                        hook, so there is nothing to wait on)
#   3   INSTALL_FAILED   the finished line is present and so is an INSTALL FAILED line
#   4   STILL_RUNNING    this call's attempts are spent while the job is alive and
#                        the bound has not passed: call again
#   5   DEADLINE_PASSED  the job is alive but the bound has passed with no finished line
#   6   STOPPED          no finished line, and no pid file or a dead recorded pid
#   2   a refusal: a usage error, or --tree is not a git work tree
# STOPPED is checked before DEADLINE_PASSED, so a dead job past the bound reads
# as STOPPED, the more accurate of the two.
#
# WHY A BOUNDED CALL AND NOT A LOOP TO COMPLETION. A Bash tool call times out
# at two minutes, so the defaults (nine attempts, ten seconds apart) keep one
# call under it and the caller calls again on STILL_RUNNING. An unbounded shell
# sleep loop is the shape this script exists to replace: if the install job dies
# without writing its finished line, such a loop never ends.
#
# WHY NO STATE BETWEEN CALLS. The bound is measured from the pid file's mtime,
# which the install job writes when it starts, so every call recomputes the
# deadline from the filesystem and none needs a counter of earlier calls.
#
# The log and pid file live in the tree's own git directory, which differs per
# linked worktree, so the script derives it from --tree rather than the cwd.
#
# Bash 3.2 compatible, BSD and GNU stat. Never `cd`.

set -uo pipefail

PROGRAM_NAME="provision-wait.sh"

DEFAULT_BOUND=600
DEFAULT_ATTEMPTS=9
DEFAULT_INTERVAL=10

FINISHED_LINE="provision-worktree: provisioning finished"
INSTALL_FAILED_MARKER="INSTALL FAILED"

usage() {
  cat <<EOF
Usage: bash .gaia/scripts/$PROGRAM_NAME --tree <absolute worktree path>
                                [--bound <seconds>] [--attempts <n>]
                                [--interval <seconds>]

  --tree      the linked worktree whose install to wait on. Required, absolute.
  --bound     seconds after the install job started (the pid file's mtime) past
              which a still-running job is DEADLINE_PASSED. Default $DEFAULT_BOUND.
  --attempts  how many times to read the log in this call. Default $DEFAULT_ATTEMPTS.
  --interval  seconds to sleep between reads. Default $DEFAULT_INTERVAL. Zero is allowed.

Prints one verdict token, then the log path, and exits:
  FINISHED (0), INSTALL_FAILED (3), STILL_RUNNING (4), DEADLINE_PASSED (5),
  STOPPED (6). Exit 2 is a refusal rather than a verdict.
EOF
}

TREE=""
BOUND="$DEFAULT_BOUND"
ATTEMPTS="$DEFAULT_ATTEMPTS"
INTERVAL="$DEFAULT_INTERVAL"

# A non-negative integer, and nothing else. A bad value is refused loudly
# because a silently defaulted bound turns a deliberate short wait into a
# ten-minute one.
is_non_negative_integer() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tree)
      [ "$#" -ge 2 ] || { printf '%s: --tree needs a value\n' "$PROGRAM_NAME" >&2; exit 2; }
      TREE="$2"
      shift 2
      ;;
    --bound)
      [ "$#" -ge 2 ] || { printf '%s: --bound needs a value\n' "$PROGRAM_NAME" >&2; exit 2; }
      BOUND="$2"
      shift 2
      ;;
    --attempts)
      [ "$#" -ge 2 ] || { printf '%s: --attempts needs a value\n' "$PROGRAM_NAME" >&2; exit 2; }
      ATTEMPTS="$2"
      shift 2
      ;;
    --interval)
      [ "$#" -ge 2 ] || { printf '%s: --interval needs a value\n' "$PROGRAM_NAME" >&2; exit 2; }
      INTERVAL="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf '%s: unknown argument: %s\n' "$PROGRAM_NAME" "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$TREE" ]; then
  printf '%s: --tree is required\n' "$PROGRAM_NAME" >&2
  usage >&2
  exit 2
fi
case "$TREE" in
  /*) ;;
  *)
    printf '%s: --tree must be an absolute path: %s\n' "$PROGRAM_NAME" "$TREE" >&2
    exit 2
    ;;
esac
if ! is_non_negative_integer "$BOUND"; then
  printf '%s: --bound must be a non-negative integer, got: %s\n' "$PROGRAM_NAME" "$BOUND" >&2
  exit 2
fi
if ! is_non_negative_integer "$ATTEMPTS" || [ "$ATTEMPTS" -lt 1 ]; then
  printf '%s: --attempts must be a positive integer, got: %s\n' "$PROGRAM_NAME" "$ATTEMPTS" >&2
  exit 2
fi
if ! is_non_negative_integer "$INTERVAL"; then
  printf '%s: --interval must be a non-negative integer, got: %s\n' "$PROGRAM_NAME" "$INTERVAL" >&2
  exit 2
fi

if ! GIT_DIRECTORY="$(git -C "$TREE" rev-parse --absolute-git-dir 2>/dev/null)" || [ -z "$GIT_DIRECTORY" ]; then
  printf '%s: not a git work tree: %s\n' "$PROGRAM_NAME" "$TREE" >&2
  exit 2
fi

LOG_FILE="$GIT_DIRECTORY/gaia-provision.log"
PID_FILE="$GIT_DIRECTORY/gaia-provision.pid"

emit() {
  printf '%s\n' "$1"
  printf 'Log: %s\n' "$LOG_FILE"
}

# GNU stat first: on BSD `-c` is an illegal option and fails, falling through
# to BSD's `-f %m`. The reverse order is wrong, because GNU `stat -f` means
# filesystem status, prints something and exits 0.
file_modification_time() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Provisioning that ran inline in the hook never writes a log, so an absent log
# means the install already completed before this script was called.
if [ ! -f "$LOG_FILE" ]; then
  emit FINISHED
  exit 0
fi

attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
  last_line="$(grep -v '^[[:space:]]*$' "$LOG_FILE" 2>/dev/null | tail -n 1)"
  if [ "$last_line" = "$FINISHED_LINE" ]; then
    if grep -qF -- "$INSTALL_FAILED_MARKER" "$LOG_FILE" 2>/dev/null; then
      emit INSTALL_FAILED
      exit 3
    fi
    emit FINISHED
    exit 0
  fi

  recorded_pid=""
  if [ -f "$PID_FILE" ]; then
    recorded_pid="$(tr -d '[:space:]' <"$PID_FILE" 2>/dev/null)"
  fi
  if ! is_non_negative_integer "$recorded_pid" || ! kill -0 "$recorded_pid" 2>/dev/null; then
    emit STOPPED
    exit 6
  fi

  started_at="$(file_modification_time "$PID_FILE")"
  if is_non_negative_integer "$started_at"; then
    now="$(date +%s)"
    if [ "$now" -gt $((started_at + BOUND)) ]; then
      emit DEADLINE_PASSED
      exit 5
    fi
  fi

  if [ "$attempt" -lt "$ATTEMPTS" ] && [ "$INTERVAL" -gt 0 ]; then
    sleep "$INTERVAL"
  fi
  attempt=$((attempt + 1))
done

emit STILL_RUNNING
exit 4
