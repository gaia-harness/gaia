#!/usr/bin/env bash
# shellcheck shell=bash
#
# The shared rate-limit reading arm of block-audit-loop-write.sh. Sourced by
# that guard after its own helpers (shell_scan, writes_named,
# runs_guarded_script, physical_path) are defined; it is not a hook and carries
# no registration.
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

# gaia_rate_limits_guard_path <literal-path> <resolved-path> <main-root>
# rc 0 when the path names the shared file: by its literal spelling (survives a
# symlink that cannot be resolved), by its physical resolution, or by the main
# checkout's own path (the resolved form of a linked worktree's symlink).
gaia_rate_limits_guard_path() {
  local literal_path="$1" resolved_path="$2" main_root="$3"
  case "$literal_path" in
    *"$GAIA_RATE_LIMITS_GUARD_SHARED_SUFFIX") return 0 ;;
  esac
  case "$resolved_path" in
    *"$GAIA_RATE_LIMITS_GUARD_SHARED_SUFFIX") return 0 ;;
  esac
  if [ -n "$main_root" ]; then
    [ "$resolved_path" != "$main_root/.gaia/local/$GAIA_RATE_LIMITS_GUARD_SHARED_SUFFIX" ] || return 0
  fi
  return 1
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

# words_run_rate_limits_write: rc 0 when the simple command held in the `words`
# array executes rate-limits.sh with `write` as its first argument (command
# word, or script argument of a shell or `source`/`.`/`exec`). A lone `-n`
# syntax check is excepted, and any other verb, `read` included, is allowed.
# `words` is the array runs_guarded_script fills
# shellcheck disable=SC2154
words_run_rate_limits_write() {
  local count=${#words[@]} word_index=0 word base syntax_check
  while [ "$word_index" -lt "$count" ]; do
    case "${words[$word_index]}" in
      [A-Za-z_]*=* | '!' | exec) word_index=$((word_index + 1)) ;;
      *) break ;;
    esac
  done
  [ "$word_index" -lt "$count" ] || return 1

  word="${words[$word_index]}"
  case "$word" in
    rate-limits.sh | */rate-limits.sh)
      [ "${words[$((word_index + 1))]-}" = write ]
      return
      ;;
  esac
  base="${word##*/}"
  case "$base" in
    bash | sh | zsh | dash | ksh | source | .)
      syntax_check=0
      word_index=$((word_index + 1))
      while [ "$word_index" -lt "$count" ]; do
        word="${words[$word_index]}"
        case "$word" in
          -n) syntax_check=1 ;;
          -o | +o) word_index=$((word_index + 1)) ;;
          -* | +*) ;;
          rate-limits.sh | */rate-limits.sh)
            if [ "$syntax_check" -eq 0 ] && [ "${words[$((word_index + 1))]-}" = write ]; then
              return 0
            fi
            break
            ;;
          *) break ;;
        esac
        word_index=$((word_index + 1))
      done
      ;;
  esac
  return 1
}

# gaia_rate_limits_guard_runs_write <command>: rc 0 when a simple command in
# the line executes rate-limits.sh with the write verb.
gaia_rate_limits_guard_runs_write() {
  case "$1" in
    *rate-limits.sh*) ;;
    *) return 1 ;;
  esac
  runs_guarded_script "$1" words_run_rate_limits_write
}
