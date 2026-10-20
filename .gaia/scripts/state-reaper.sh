#!/usr/bin/env bash
# shellcheck shell=bash
#
# Backstop reaper: walks the committed state registry and applies each local
# row's retention class to the main checkout's .gaia/local, `protected/`
# included. The vocabulary of classes, keys and windows is owned by the header
# of state-reaper-lib.sh; nothing is restated here.
#
# Launched detached by the SessionStart hook, from any tree. It resolves the
# main checkout from its own location, never from the working directory or the
# environment, so the main checkout's copy reaps the main checkout's state and
# reaper code and registry agree. Claude is denied executing it, because the
# hook process is the only caller trusted to reach `protected/`.
#
# One run at a time: `cache/state-reaper/run.lock.d` is taken by `mkdir` and
# reclaimed once older than the stale window, which outlasts any real run, so
# a killed run cannot block every later one. A held lock ends the run quietly.
#
# Each run overwrites `cache/state-reaper/last-run.json` atomically:
#   {"schema":1,"started_at":...,"finished_at":...,
#    "removed":{"<row-id>":<count>},"skipped":["<reason>",...]}
# `removed` lists only rows that removed something; `skipped` carries every
# liveness source or row the run declined to act on.
#
# Always exits 0. A reaper error must never block the session that launched
# it, so a missing tool, an unreadable registry or a failed git read removes
# nothing and still ends cleanly. It accepts no arguments and reads no
# environment override of the clock, windows, root or lock: a file that can
# delete protected state offers no knob to widen what it deletes.

_STATE_REAPER_LOCK_STALE_MINUTES=60

state_reaper_release_lock=""

# shellcheck disable=SC2329  # runs as the EXIT trap
state_reaper_cleanup() {
  [ -n "$state_reaper_release_lock" ] || return 0
  [ "$(cat "$state_reaper_release_lock/owner" 2>/dev/null)" = "$$" ] && rm -rf "$state_reaper_release_lock" 2>/dev/null
  return 0
}

state_reaper_lock_is_stale() {
  [ -n "$(find "$1" -maxdepth 0 -mmin +"$_STATE_REAPER_LOCK_STALE_MINUTES" 2>/dev/null)" ]
}

# state_reaper_take_lock <lock-directory>: rc 0 when this run holds it. A stale
# lock is renamed aside and its age re-checked on the renamed copy, because two
# contenders can both see the same stale lock and the faster one may already
# have retaken a live lock in its place; a live lock is handed back.
state_reaper_take_lock() {
  local lock="$1"
  if ! mkdir "$lock" 2>/dev/null; then
    state_reaper_lock_is_stale "$lock" && mv "$lock" "$lock.stale.$$" 2>/dev/null || return 1
    if ! state_reaper_lock_is_stale "$lock.stale.$$"; then
      mv "$lock.stale.$$" "$lock" 2>/dev/null
      return 1
    fi
    rm -rf "$lock.stale.$$" 2>/dev/null
    mkdir "$lock" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" >"$lock/owner" 2>/dev/null
  state_reaper_release_lock="$lock"
  return 0
}

# state_reaper_write_record <state-directory> <started-at> <removed-tsv> <skipped-lines>
state_reaper_write_record() {
  local state_directory="$1" started_at="$2" removed_tsv="$3" skipped_lines="$4" finished_at temporary
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  temporary="$state_directory/last-run.json.tmp.$$"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg started "$started_at" --arg finished "$finished_at" --arg removed "$removed_tsv" --arg skipped "$skipped_lines" '
      {schema: 1, started_at: $started, finished_at: $finished,
       removed: ($removed | split("\n") | map(select(length > 0) | split("\t")) | map({key: .[0], value: (.[1] | tonumber)}) | from_entries),
       skipped: ($skipped | split("\n") | map(select(length > 0)))}' >"$temporary" 2>/dev/null || {
      rm -f "$temporary" 2>/dev/null
      return 0
    }
  else
    printf '{"schema":1,"started_at":"%s","finished_at":"%s","removed":{},"skipped":["jq is not available"]}\n' \
      "$started_at" "$finished_at" >"$temporary" 2>/dev/null || return 0
  fi
  mv -f "$temporary" "$state_directory/last-run.json" 2>/dev/null || rm -f "$temporary" 2>/dev/null
  return 0
}

state_reaper_main() {
  local script_directory main_root local_root state_directory started_at registry
  local index row_id row_json row_class output line count removed_tsv="" skipped_lines="" disabled
  if [ "$#" -gt 0 ]; then
    printf 'usage: state-reaper.sh (takes no arguments)\n' >&2
    return 0
  fi
  command -v git >/dev/null 2>&1 || return 0
  script_directory="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd -P)" || return 0
  # shellcheck source=/dev/null
  . "$script_directory/state-reaper-classes.sh" || return 0
  main_root="$(gaia_resolve_main_root "$script_directory" 2>/dev/null)" || return 0
  local_root="$main_root/.gaia/local"
  state_directory="$local_root/cache/state-reaper"
  [ -d "$local_root" ] && [ ! -L "$local_root" ] || return 0
  [ ! -L "$local_root/cache" ] || return 0
  mkdir -p "$state_directory" 2>/dev/null || return 0
  [ -d "$state_directory" ] && [ ! -L "$state_directory" ] || return 0
  state_reaper_take_lock "$state_directory/run.lock.d" || return 0
  trap state_reaper_cleanup EXIT
  trap 'exit 0' INT TERM HUP
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  registry="$main_root/.gaia/state-registry.json"
  if ! command -v jq >/dev/null 2>&1; then
    state_reaper_write_record "$state_directory" "$started_at" "" "jq is not available"
    return 0
  fi
  if ! gaia_reaper_load_registry "$registry"; then
    state_reaper_write_record "$state_directory" "$started_at" "" "the state registry is missing or unreadable"
    return 0
  fi
  gaia_reaper_snapshot "$main_root"
  skipped_lines="$GAIA_REAPER_SKIPPED"
  # A failed ref read leaves the worktree list intact, but a tree key is only
  # trusted next to a branch snapshot that also loaded: one failed git read
  # means the repository state is not understood, so no keyed row runs.
  disabled=0
  if [ -z "${GAIA_REAPER_BRANCHES_OK-}" ] || [ -z "${GAIA_REAPER_TREES_OK-}" ]; then
    disabled=1
  fi
  index=0
  while [ "$index" -lt "${#GAIA_REAPER_ROW_IDS[@]}" ]; do
    row_id="${GAIA_REAPER_ROW_IDS[index]}"
    row_json="${GAIA_REAPER_ROW_JSONS[index]}"
    index=$((index + 1))
    row_class="$(printf '%s' "$row_json" | jq -r '.retention.class // ""' 2>/dev/null)"
    if [ "$disabled" = 1 ]; then
      case "$row_class" in
        branch-spent | tree-gone)
          skipped_lines="${skipped_lines:+$skipped_lines
}$row_id: the branch refs or the worktree list could not be read"
          continue
          ;;
      esac
    fi
    output="$(gaia_reaper_reap_row "$main_root" "$row_json")"
    count=0
    while IFS= read -r line; do
      case "$line" in
        "removed "*) count=$((count + 1)) ;;
        "skipped "*) skipped_lines="${skipped_lines:+$skipped_lines
}${line#skipped }" ;;
      esac
    done <<<"$output"
    if [ "$count" -gt 0 ]; then
      removed_tsv="${removed_tsv:+$removed_tsv
}$row_id"$'\t'"$count"
    fi
  done
  state_reaper_write_record "$state_directory" "$started_at" "$removed_tsv" "$skipped_lines"
  return 0
}

state_reaper_main "$@"
exit 0
