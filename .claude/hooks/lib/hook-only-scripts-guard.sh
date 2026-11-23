#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # the deny reasons and SCRIPT_KIND are read by the sourcing guard
#
# The hook-only script classes of block-audit-loop-write.sh: the audit loop
# recorders and the local-state reaper scripts, which execute only as hooks.
# Holds their deny reasons and the matcher that names them, which the walker
# in audit-loop-write-scan.sh calls by name. Sourced by that guard; it is not a
# hook and carries no registration.
#
# Bash 3.2 compatible.

DENY_RECORDER_MESSAGE="BLOCKED: block-audit-loop-write.sh: audit-loop-grant.sh and audit-loop-ask-grant.sh run only as hooks. Claude never executes them from Bash or Monitor, because a piped payload would forge a checkpoint answer. A human answers a checkpoint through the pinned AskUserQuestion, or by typing a whole prompt that is exactly the audit-grant <n> or audit-accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint). Naming the files (git add, git diff, git grep -l, shellcheck, cat, bash -n) is allowed."
DENY_REAPER_MESSAGE="BLOCKED: block-audit-loop-write.sh: the local-state reaper scripts (state-reaper.sh, state-reaper-lib.sh, state-reaper-classes.sh and state-reaper-session-start.sh) execute only as hooks. The reaper prunes <main>/.gaia/local/protected/, which Claude never writes or deletes, so Claude never executes them from Bash or Monitor. Naming the files (git add, git diff, git grep -l, shellcheck, cat, bash -n) and running a bats suite for them is allowed. A line inside a heredoc body that begins with a reaper script name reads as running it, unless it is a cat or tee heredoc into a file (quote its delimiter): to write text that names the scripts, use the Write tool, or a one-line printf with a quoted string (newlines as \\n)."

# guarded_script_kind <word>: rc 0 when the word's file name is one of the two
# recorders or one of the four reaper scripts; sets SCRIPT_KIND to the deny
# class (recorder or reaper). The default matcher of words_run_guarded_script.
# shellcheck disable=SC2329
guarded_script_kind() {
  case "$1" in
    audit-loop-grant.sh | */audit-loop-grant.sh | audit-loop-ask-grant.sh | */audit-loop-ask-grant.sh)
      SCRIPT_KIND=recorder
      return 0
      ;;
    state-reaper.sh | */state-reaper.sh | state-reaper-lib.sh | */state-reaper-lib.sh | state-reaper-classes.sh | */state-reaper-classes.sh | state-reaper-session-start.sh | */state-reaper-session-start.sh)
      SCRIPT_KIND=reaper
      return 0
      ;;
  esac
  return 1
}
