#!/usr/bin/env bash
# shellcheck shell=bash
#
# The per-session rate-limit reading arm of block-audit-loop-write.sh. Sourced
# by that guard after audit-loop-write-scan.sh, which defines the shell_scan,
# writes_named and runs_guarded_script this arm calls; it is not a hook and
# carries no registration.
#
# WHY. The dispatch checkpoint trusts each session's own rate-limit reading
# (one file per session under the readings folder) and the marker that records
# the checkpoint it already raised (one file per session under the marker
# folder), and the 7-day bands trust the plan tier in Claude Code's account
# profile. A session that could write a reading or a marker through its own
# tools, run the CLI's write verb, or change the tier the bands follow could
# silence or forge the checkpoint. The statusline writes a reading on each
# render through the CLI's library and the dispatch checkpoint hook writes the markers; a session's
# Write, Edit, MultiEdit, Bash or Monitor call never does. The guard refuses the
# natural spellings only; its header names the spellings it does not read.
#
# The readings folder and the marker folder (the folder itself and
# anything in it), and the legacy shared file, are guarded as paths, read the
# way the guard reads every other guarded path. `rate-limits.sh` run with the
# `write` verb is refused. The tier is guarded two ways: an Edit, Write or
# MultiEdit of a `.claude.json` whose new text names the tier field, or a command
# that writes a `.claude.json` and names it; and a command that sets
# CLAUDE_CONFIG_DIR to any folder and names `rate-limits.sh`, since the CLI
# could then read another profile's tier. Reading stays allowed.
#
# The root comes from the caller, so this file holds no bare local-state path.
#
# Bash 3.2 compatible.

# Path fragments below the main checkout's local state. Slashless, so each also
# names the folder spelled with no trailing slash; the first also covers the
# legacy shared file `rate-limits.json`.
GAIA_RATE_LIMITS_GUARD_READINGS_SUFFIX='cache/shared/rate-limits'
GAIA_RATE_LIMITS_GUARD_MARKERS_SUFFIX='cache/rate-limit-checkpoint'
GAIA_RATE_LIMITS_GUARD_TIER_FIELD='organizationRateLimitTier'

# shellcheck disable=SC2034 # read by the sourcing guard's deny
DENY_RATE_LIMITS_MESSAGE="BLOCKED: block-audit-loop-write.sh: a session's rate-limit reading (<main>/.gaia/local/cache/shared/rate-limits/<session>.json) is written by the statusline on each render, and the dispatch checkpoint trusts it, as it trusts the checkpoint markers under <main>/.gaia/local/cache/rate-limit-checkpoint/. Claude never writes, edits, moves or deletes a reading, a marker or the folder holding them, and never runs rate-limits.sh with the write verb. A human clears a wrong reading by deleting the file in their own shell outside Claude Code. Reading it (rate-limits.sh read, cat, jq) is allowed."

# shellcheck disable=SC2034 # read by the sourcing guard's deny
DENY_RATE_LIMITS_TIER_MESSAGE="BLOCKED: block-audit-loop-write.sh: the 7-day bands of the rate-limit readings (<main>/.gaia/local/cache/shared/rate-limits/) follow the plan tier in Claude Code's account profile, so Claude never writes a .claude.json that names organizationRateLimitTier, and never runs rate-limits.sh while setting CLAUDE_CONFIG_DIR. A human changes the tier in their own shell outside Claude Code. Reading it (jq of .claude.json) is allowed."

# gaia_rate_limits_guard_path <literal-path> <resolved-path>
# rc 0 when the path names a reading, a marker, either folder or the legacy
# file: by its literal spelling (survives a symlink that cannot be resolved) or
# by its physical resolution (a linked worktree's symlink resolves to the main
# checkout's folder).
gaia_rate_limits_guard_path() {
  [[ $1 == *"$GAIA_RATE_LIMITS_GUARD_READINGS_SUFFIX"* || $2 == *"$GAIA_RATE_LIMITS_GUARD_READINGS_SUFFIX"* ||
    $1 == *"$GAIA_RATE_LIMITS_GUARD_MARKERS_SUFFIX"* || $2 == *"$GAIA_RATE_LIMITS_GUARD_MARKERS_SUFFIX"* ]]
}

# gaia_rate_limits_guard_writes_file <command>
# rc 0 when the command writes, moves or deletes a reading, a marker, either
# folder or the legacy file, read the way the guard reads every other guarded
# path (redirect target, or a write verb outside quotes, with the unsound-reading
# fallback). Naming one to read it (cat, jq) is allowed.
gaia_rate_limits_guard_writes_file() {
  local delimiters='[[:space:]"'\'';|&)<>]'
  local names_re="($GAIA_RATE_LIMITS_GUARD_READINGS_SUFFIX(\\.json)?|$GAIA_RATE_LIMITS_GUARD_MARKERS_SUFFIX)(/|$delimiters|\$)"
  [[ "$1" =~ $names_re ]] || return 1
  # Rescanned: runs_guarded_script, called before this, overwrites the scan.
  shell_scan "$1"
  writes_named "$1" "$names_re"
}

# names_rate_limits_write <script-word> <next-word>: the words_run_guarded_script
# matcher for rate-limits.sh run with `write` as its first argument (the session
# id and the reading follow; a lone `-n` syntax check is excepted by the
# walker). Any other verb, `read` included, is allowed.
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

# gaia_rate_limits_guard_sets_config_dir <command>: rc 0 when the command sets
# CLAUDE_CONFIG_DIR (an assignment prefix, `export`, `env`) and names
# rate-limits.sh as a word, so the CLI would read another folder's profile.
# Reading the variable (`$CLAUDE_CONFIG_DIR`) is not setting it.
gaia_rate_limits_guard_sets_config_dir() {
  local sets_re='(^|[[:space:];&|(])CLAUDE_CONFIG_DIR=' script_re='rate-limits\.sh([[:space:]"'\'';|&)<>]|$)'
  [[ "$1" =~ $sets_re ]] && [[ "$1" =~ $script_re ]]
}

# gaia_rate_limits_guard_edits_tier <literal-path> <resolved-path> <raw-payload>
# rc 0 when an Edit, Write or MultiEdit targets a `.claude.json` and its new text
# (`content`, `new_string`, or any `edits[].new_string`) names the tier field. The
# text is outside the fixed payload fields, so one jq reads it, and only after
# the path ends in `.claude.json`.
gaia_rate_limits_guard_edits_tier() {
  [[ $1 == *.claude.json || $2 == *.claude.json ]] || return 1
  jq -e --arg field "$GAIA_RATE_LIMITS_GUARD_TIER_FIELD" '[.tool_input | (.content, .new_string, (.edits[]?.new_string))] | map(select(type == "string")) | any(contains($field))' <<<"$3" >/dev/null 2>&1
}

# gaia_rate_limits_guard_writes_tier <command>: rc 0 when the command writes a
# `.claude.json` (redirect target, or a write verb outside quotes) and names the
# tier field. A read-only jq of the field is allowed.
gaia_rate_limits_guard_writes_tier() {
  local names_re='\.claude\.json([[:space:]"'\'';|&)<>]|$)'
  case "$1" in
    *"$GAIA_RATE_LIMITS_GUARD_TIER_FIELD"*) ;;
    *) return 1 ;;
  esac
  [[ "$1" =~ $names_re ]] || return 1
  shell_scan "$1"
  writes_named "$1" "$names_re"
}
