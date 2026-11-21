#!/usr/bin/env bash
# shellcheck shell=bash
#
# The shared rate-limit reading arm of block-audit-loop-write.sh. Sourced by
# that guard after audit-loop-write-scan.sh, which defines the shell_scan,
# writes_named and runs_guarded_script this arm calls; it is not a hook and
# carries no registration.
#
# WHY. Every session trusts the shared rate-limit reading, and the dispatch
# checkpoint acts on it, so a session must not forge or erase it through its own
# tools. The statusline writes it on each render through the CLI's library; a
# session's Write, Edit, MultiEdit, Bash or Monitor call never does. The guard
# refuses the natural spellings only; its header names the spellings it does not
# read.
#
# The root comes from the caller, so this file holds no bare local-state path.
#
# Bash 3.2 compatible.

# The shared file's path below the main checkout's local state.
GAIA_RATE_LIMITS_GUARD_SHARED_SUFFIX='cache/shared/rate-limits.json'

# shellcheck disable=SC2034 # read by the sourcing guard's deny
DENY_RATE_LIMITS_MESSAGE="BLOCKED: block-audit-loop-write.sh: the shared rate-limit reading (<main>/.gaia/local/cache/shared/rate-limits.json) is written by the statusline on each render, and the dispatch checkpoint trusts it. Claude never writes, edits, moves or deletes it, and never runs rate-limits.sh with the write verb. A human clears a wrong reading by deleting the file in their own shell outside Claude Code. Reading it (rate-limits.sh read, cat, jq) is allowed."

# gaia_rate_limits_guard_path <literal-path> <resolved-path>
# rc 0 when the path names the shared file: by its literal spelling (survives a
# symlink that cannot be resolved) or by its physical resolution (a linked
# worktree's symlink resolves to the main checkout's file).
gaia_rate_limits_guard_path() {
  [[ $1 == *"$GAIA_RATE_LIMITS_GUARD_SHARED_SUFFIX" || $2 == *"$GAIA_RATE_LIMITS_GUARD_SHARED_SUFFIX" ]]
}

# gaia_rate_limits_guard_writes_file <command>
# rc 0 when the command writes, moves or deletes the shared file, read the way
# the guard reads every other guarded path (redirect target, or a write verb
# outside quotes, with the unsound-reading fallback). Naming the file to read it
# (cat, jq) is allowed.
gaia_rate_limits_guard_writes_file() {
  local names_re='cache/shared/rate-limits\.json([[:space:]"'\'';|&)<>]|$)'
  [[ "$1" =~ $names_re ]] || return 1
  shell_scan "$1"
  writes_named "$1" "$names_re"
}

# names_rate_limits_write <script-word> <next-word>: the words_run_guarded_script
# matcher for rate-limits.sh run with `write` as its first argument (a lone `-n`
# syntax check is excepted by the walker). Any other verb, `read` included, is
# allowed.
# invoked through runs_guarded_script's matcher name
# shellcheck disable=SC2329
names_rate_limits_write() {
  case "$1" in
    rate-limits.sh | */rate-limits.sh) [ "${2-}" = write ] ;;
    *) return 1 ;;
  esac
}

# gaia_rate_limits_guard_runs_write <command>: rc 0 when a simple command in
# the line executes rate-limits.sh with the write verb.
gaia_rate_limits_guard_runs_write() {
  case "$1" in
    *rate-limits.sh*) ;;
    *) return 1 ;;
  esac
  runs_guarded_script "$1" names_rate_limits_write
}
