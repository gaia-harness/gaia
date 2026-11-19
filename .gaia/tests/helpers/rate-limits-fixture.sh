#!/usr/bin/env bash
# Shared bats fixture for the shared rate-limit reading. A cross-directory
# helper (see path.sh for the reach convention), sourced from a suite's setup().
#
# It writes the stored file directly rather than through the library's writer,
# because suites seed more windows than the writer accepts.

# rate_limits_seed_file <file> <now> <name> <percentage> <resets_at> [<name> <percentage> <resets_at> ...]:
# a valid version-1 stored file, every window observed at <now>.
rate_limits_seed_file() {
  local file="$1" now="$2" windows='{}'
  shift 2
  while [ "$#" -ge 3 ]; do
    windows=$(jq -c --arg name "$1" --argjson percentage "$2" --argjson resets_at "$3" --argjson observed_at "$now" \
      '.[$name] = {used_percentage: $percentage, resets_at: $resets_at, observed_at: $observed_at, producer: "statusline",
        history: [{used_percentage: $percentage, observed_at: $observed_at, producer: "statusline"}]}' <<<"$windows")
    shift 3
  done
  mkdir -p "${file%/*}"
  jq -n --argjson windows "$windows" '{version: 1, windows: $windows}' >"$file"
}
