#!/usr/bin/env bash
# Shared bats fixture for the per-session rate-limit reading. A cross-directory
# helper (see path.sh for the reach convention), sourced from a suite's setup().
#
# It writes a session's reading file directly rather than through the
# library's writer, because the writer stamps its own clock and marks a first
# reading unconfirmed, and suites need to seed either state at any time.

# rate_limits_seed_session <main-root> <session-id> <changed_at> <confirmed true|false> <name> <percentage> <resets_at> [<name> <percentage> <resets_at> ...]:
# a valid version-2 reading file for that session, every window changed at
# <changed_at> with that confirmed flag and one history entry.
rate_limits_seed_session() {
  local root="$1" session_id="$2" changed_at="$3" confirmed="$4" windows='{}' file
  shift 4
  while [ "$#" -ge 3 ]; do
    windows=$(jq -c --arg name "$1" --argjson percentage "$2" --argjson resets_at "$3" \
      --argjson changed_at "$changed_at" --argjson confirmed "$confirmed" \
      '.[$name] = {used_percentage: $percentage, resets_at: $resets_at, changed_at: $changed_at, confirmed: $confirmed,
        history: [{used_percentage: $percentage, changed_at: $changed_at}]}' <<<"$windows")
    shift 3
  done
  file="$root/.gaia/local/cache/shared/rate-limits/$session_id.json"
  mkdir -p "${file%/*}"
  jq -nc --argjson windows "$windows" '{version: 2, windows: $windows}' >"$file"
}
