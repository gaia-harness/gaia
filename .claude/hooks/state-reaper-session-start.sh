#!/usr/bin/env bash
# SessionStart hook (startup|resume): launches the backstop state reaper
# detached, at most once per 24 hours, from any tree. The launch stamp, the
# lock and the reaper all live under the main checkout's .gaia/local, so a
# linked worktree and the main checkout share one cadence. Sessions that never
# open the statusline from main still get the age sweep this way.
#
# Budget: about 20 ms synchronous (one main-root resolution, one mtime probe,
# one fork). The reaper's own work runs detached and is not in that figure. No
# network call, no transcript read; stdin is read and discarded.
#
# Launches main's copy of the reaper, not this tree's: the reaper code and the
# registry it reads then come from the same checkout and agree on versions.
#
# Always exits 0 and prints nothing. An unresolvable main root, an absent
# reaper, an unwritable cache or a lost lock each mean no launch this time.

set -uo pipefail
trap 'exit 0' ERR

cat >/dev/null 2>&1 || true

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
main_root_library="$here/../../.gaia/scripts/main-root-lib.sh"
[ -f "$main_root_library" ] || exit 0
# shellcheck source=/dev/null
source "$main_root_library" || exit 0

main_root="$(gaia_resolve_main_root 2>/dev/null)" || exit 0
[ -n "$main_root" ] || exit 0

reaper="$main_root/.gaia/scripts/state-reaper.sh"
[ -f "$reaper" ] || exit 0

STAMP_TTL_MINUTES=1440
LOCK_STALE_MINUTES=10
state_directory="$main_root/.gaia/local/cache/state-reaper"
stamp="$state_directory/last-launch"
lock_directory="$state_directory/launch.lock.d"

mkdir -p "$state_directory" 2>/dev/null || exit 0

# A missing stamp reads as stale: find prints nothing for it, so test for the
# file first.
stamp_is_fresh() {
  [ -f "$stamp" ] && [ -z "$(find "$stamp" -maxdepth 0 -mmin +"$STAMP_TTL_MINUTES" 2>/dev/null)" ]
}

lock_is_stale() {
  [ -n "$(find "$1" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null)" ]
}

stamp_is_fresh && exit 0

# Single flight: mkdir is the atomic test-and-set. A lock older than
# LOCK_STALE_MINUTES belongs to a hook killed before it released; it is renamed
# aside, re-checked on the renamed directory (a rename keeps its mtime) so a
# live lock another contender just retook is handed back, and retaken.
if ! mkdir "$lock_directory" 2>/dev/null; then
  if lock_is_stale "$lock_directory" && mv "$lock_directory" "$lock_directory.stale.$$" 2>/dev/null; then
    if ! lock_is_stale "$lock_directory.stale.$$"; then
      mv "$lock_directory.stale.$$" "$lock_directory" 2>/dev/null
      exit 0
    fi
    rm -rf "$lock_directory.stale.$$" 2>/dev/null
    mkdir "$lock_directory" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$lock_directory" 2>/dev/null; exit 0' EXIT

# Re-read under the lock: a contender may have launched between the gate above
# and the mkdir.
stamp_is_fresh && exit 0

touch "$stamp" 2>/dev/null || exit 0

# The redirects are what release the hook's pipes; without them the harness
# waits for the reaper to exit.
"${BASH:-bash}" "$reaper" </dev/null >/dev/null 2>&1 &
disown "$!" 2>/dev/null || true
exit 0
