#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # the deny reasons and SCRIPT_KIND are read by the sourcing guard
#
# The hook-only script classes of block-audit-loop-write.sh: the audit loop
# recorders, the local-state reaper scripts and the context writers, which
# execute only as hooks or as the statusline. Holds their deny reasons and the
# matchers that name them, which the walker in audit-loop-write-scan.sh calls
# by name. Sourced by that guard; it is not a
# hook and carries no registration.
#
# Bash 3.2 compatible.

DENY_QUOTED_SEPARATOR_LIMIT=", except that a quoted |, ;, &, (, ), backtick or newline in an argument reads as a command separator and can get such a command denied; to search a file, use the Read tool, or grep with one -e <pattern> per alternative, none holding those characters."

DENY_RECORDER_MESSAGE="BLOCKED: block-audit-loop-write.sh: audit-loop-grant.sh and audit-loop-ask-grant.sh run only as hooks. Claude never executes them from Bash or Monitor, because a piped payload would forge a checkpoint answer. A human answers a checkpoint through the pinned AskUserQuestion, or by typing a whole prompt that is exactly the audit-grant <n> or audit-accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint). Naming the files (git add, git diff, git grep -l, shellcheck, cat, bash -n) is allowed$DENY_QUOTED_SEPARATOR_LIMIT"
DENY_REAPER_MESSAGE="BLOCKED: block-audit-loop-write.sh: the local-state reaper scripts (state-reaper.sh, state-reaper-lib.sh, state-reaper-classes.sh and state-reaper-session-start.sh) execute only as hooks. The reaper prunes <main>/.gaia/local/protected/, which Claude never writes or deletes, so Claude never executes them from Bash or Monitor. Naming the files (git add, git diff, git grep -l, shellcheck, cat, bash -n) and running a bats suite for them is allowed$DENY_QUOTED_SEPARATOR_LIMIT A line inside a heredoc body that begins with a reaper script name reads as running it, unless the heredoc is a cat or tee into a file (quote its delimiter): to write text that names the scripts, use the Write tool, or a one-line printf with a quoted string (newlines as \\n)."
DENY_CONTEXT_WRITER_MESSAGE="BLOCKED: block-audit-loop-write.sh: running the statusline (gaia-statusline.sh) or a context writer (context-reading.sh, or context-checkpoint-lib.sh, context-any-age-lib.sh or gaia-next-handoff-lib.sh with gaia_context_write or gaia_statusline_write_context) mints the context reading the audit checkpoint trusts to continue on its own, so Claude never runs them from Bash or Monitor. The statusline renders as its own process. Naming the files (git add, git diff, grep, cat, shellcheck, bash -n) and running a bats suite for them is allowed$DENY_QUOTED_SEPARATOR_LIMIT"

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

# context_writer_execute_matcher <word>: rc 0 when the word's file name is the
# statusline or the context reading wrapper. Exact base names, so the left and
# right statusline segments and a bats suite path never match.
# shellcheck disable=SC2329
context_writer_execute_matcher() {
  case "$1" in
    gaia-statusline.sh | */gaia-statusline.sh | context-reading.sh | */context-reading.sh) return 0 ;;
  esac
  return 1
}

# context_writer_source_matcher <word>: rc 0 when the word's file name is the
# context checkpoint library or the context reading wrapper. Paired by the
# caller with a whole-word writer name, since sourcing the library to read is
# allowed.
# shellcheck disable=SC2329
context_writer_source_matcher() {
  case "$1" in
    context-checkpoint-lib.sh | */context-checkpoint-lib.sh | context-any-age-lib.sh | */context-any-age-lib.sh | gaia-next-handoff-lib.sh | */gaia-next-handoff-lib.sh | context-reading.sh | */context-reading.sh) return 0 ;;
  esac
  return 1
}

# names_context_writer <command>: rc 0 when the command names gaia_context_write
# or gaia_statusline_write_context as a whole word.
names_context_writer() {
  [[ "$1" =~ (^|[^A-Za-z0-9_])(gaia_context_write|gaia_statusline_write_context)([^A-Za-z0-9_]|$) ]]
}
