#!/usr/bin/env bats
# Tests for .gaia/scripts/update-check-bust.sh, the update-check cache rewrite.
#
# The property worth the fixtures is that the rewrite is a merge: the cache
# holds fields nothing can reconstruct, so each mode is asserted to change
# exactly its own keys and leave every other one byte-equivalent (compared as
# sorted JSON, with the changed keys deleted from the input). The failure arms
# assert the original file's bytes are untouched, because a bust that corrupts
# the cache while failing is worse than no bust.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md. `run`
# captures status and `$status` is compared with POSIX `[ ]`.

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BUST="$THIS_DIRECTORY/../update-check-bust.sh"
  CACHE="$BATS_TEST_TMPDIR/update-check.json"
}

write_populated_cache() {
  cat >"$CACHE" <<'EOF'
{
  "outdatedCount": 7,
  "checkedAt": 1000,
  "gaiaCurrent": "1.0.0",
  "gaiaLatest": "2.0.0",
  "gaiaHasUpdate": true,
  "cleanseMemoryBaseline": {"files": 12, "bytes": 3456},
  "codifyReviewCount": 4,
  "someFutureField": ["kept", {"nested": true}]
}
EOF
}

@test "deps zeroes outdatedCount, refreshes checkedAt and carries every other field across" {
  write_populated_cache
  local before_seconds
  before_seconds="$(date +%s)"
  run bash "$BUST" --cache "$CACHE" --mode deps
  [ "$status" -eq 0 ]
  [ "$output" = "BUSTED" ]
  [ "$(jq '.outdatedCount' "$CACHE")" = "0" ]
  local checked_at
  checked_at="$(jq '.checkedAt' "$CACHE")"
  [ "$(jq -r '.checkedAt | type' "$CACHE")" = "number" ]
  [ "$checked_at" -ge "$before_seconds" ]
  [ "$checked_at" -le $((before_seconds + 5)) ]
  local expected actual
  expected="$(jq -S 'del(.outdatedCount, .checkedAt)' <<'EOF'
{
  "outdatedCount": 7,
  "checkedAt": 1000,
  "gaiaCurrent": "1.0.0",
  "gaiaLatest": "2.0.0",
  "gaiaHasUpdate": true,
  "cleanseMemoryBaseline": {"files": 12, "bytes": 3456},
  "codifyReviewCount": 4,
  "someFutureField": ["kept", {"nested": true}]
}
EOF
)"
  actual="$(jq -S 'del(.outdatedCount, .checkedAt)' "$CACHE")"
  [ "$actual" = "$expected" ]
}

@test "gaia sets the five keys and carries every other field across" {
  write_populated_cache
  local before_seconds
  before_seconds="$(date +%s)"
  run bash "$BUST" --cache "$CACHE" --mode gaia --version 2.3.0
  [ "$status" -eq 0 ]
  [ "$output" = "BUSTED" ]
  [ "$(jq -r '.gaiaCurrent' "$CACHE")" = "2.3.0" ]
  [ "$(jq -r '.gaiaLatest' "$CACHE")" = "2.3.0" ]
  [ "$(jq '.gaiaHasUpdate' "$CACHE")" = "false" ]
  [ "$(jq '.outdatedCount' "$CACHE")" = "0" ]
  local checked_at
  checked_at="$(jq '.checkedAt' "$CACHE")"
  [ "$checked_at" -ge "$before_seconds" ]
  [ "$checked_at" -le $((before_seconds + 5)) ]
  local expected actual
  expected="$(jq -S 'del(.outdatedCount, .checkedAt, .gaiaCurrent, .gaiaLatest, .gaiaHasUpdate)' <<'EOF'
{
  "outdatedCount": 7,
  "checkedAt": 1000,
  "gaiaCurrent": "1.0.0",
  "gaiaLatest": "2.0.0",
  "gaiaHasUpdate": true,
  "cleanseMemoryBaseline": {"files": 12, "bytes": 3456},
  "codifyReviewCount": 4,
  "someFutureField": ["kept", {"nested": true}]
}
EOF
)"
  actual="$(jq -S 'del(.outdatedCount, .checkedAt, .gaiaCurrent, .gaiaLatest, .gaiaHasUpdate)' "$CACHE")"
  [ "$actual" = "$expected" ]
}

write_cache_with_claims() {
  jq -n '{
    checkedAt: 1000, gaiaCurrent: "1.0.0", gaiaLatest: "2.0.0", gaiaHasUpdate: true,
    ghLogin: "octo-cat",
    gaiaUpdateClaims: [
      {number: 41, headRefName: "update/v2.0.0-2026-10-18-1200", tag: "v2.0.0", authorLogin: "other", createdAt: "2026-10-18T12:00:00Z"},
      {number: 42, headRefName: "update/v2.0.0-2026-10-18-1300", tag: "v2.0.0", authorLogin: "octo-cat", createdAt: "2026-10-18T13:00:00Z"}
    ]
  }' >"$CACHE"
}

@test "gaia --drop-claim removes only that claim and carries every other field" {
  write_cache_with_claims
  run bash "$BUST" --cache "$CACHE" --mode gaia --version 2.0.0 --drop-claim 42
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.gaiaUpdateClaims[].number]' "$CACHE")" = "[41]" ]
  [ "$(jq -r '.ghLogin' "$CACHE")" = "octo-cat" ]
  [ "$(jq -r '.gaiaUpdateClaims[0].authorLogin' "$CACHE")" = "other" ]
}

@test "gaia without --drop-claim leaves every claim in place" {
  write_cache_with_claims
  run bash "$BUST" --cache "$CACHE" --mode gaia --version 2.0.0
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.gaiaUpdateClaims[].number]' "$CACHE")" = "[41,42]" ]
}

write_cache_behind_origin() {
  cat >"$CACHE" <<'JSON'
{
  "outdatedCount": 3,
  "checkedAt": 1000,
  "gaiaCurrent": "2.0.3",
  "gaiaLatest": "2.0.5",
  "gaiaOriginVersion": "2.0.4",
  "gaiaHasUpdate": true,
  "gaiaUpdateClaims": [{"number": 41, "login": "ada"}],
  "cleanseMemoryBaseline": {"files": 12, "bytes": 3456}
}
JSON
}

@test "pull carries the claims and every other field across" {
  write_cache_behind_origin
  local expected actual
  expected="$(jq -S 'del(.gaiaCurrent, .gaiaOriginVersion, .gaiaHasUpdate, .checkedAt)' "$CACHE")"
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4
  [ "$status" -eq 0 ]
  actual="$(jq -S 'del(.gaiaCurrent, .gaiaOriginVersion, .gaiaHasUpdate, .checkedAt)' "$CACHE")"
  [ "$actual" = "$expected" ]
  [ "$(jq -c '[.gaiaUpdateClaims[].number]' "$CACHE")" = "[41]" ]
}

@test "pull accepts a prerelease version" {
  write_cache_behind_origin
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4-rc.1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.gaiaCurrent' "$CACHE")" = "2.0.4-rc.1" ]
}

write_cache_with_fitness_fields() {
  cat >"$CACHE" <<'JSON'
{
  "outdatedCount": 7,
  "checkedAt": 1000,
  "gaiaCurrent": "1.0.0",
  "gaiaLatest": "2.0.0",
  "gaiaHasUpdate": true,
  "cleanseMemoryBaseline": {"files": 12, "bytes": 3456},
  "fitnessGrade": "B",
  "fitnessBlendCount": 3,
  "fitnessCommitCount": 41,
  "fitnessCommitThreshold": 50,
  "fitnessBlendLandedAt": 900,
  "fitnessBasisVersion": "2.0.0",
  "fitnessBasisCloseAt": 800,
  "wikiStateSha": "abc123"
}
JSON
}

@test "fitness sets checkedAt to 0 and carries every other field across" {
  write_cache_with_fitness_fields
  jq -S 'del(.checkedAt)' "$CACHE" >"$BATS_TEST_TMPDIR/expected"
  run bash "$BUST" --cache "$CACHE" --mode fitness
  [ "$status" -eq 0 ]
  [ "$output" = "BUSTED" ]
  [ "$(jq -c '.checkedAt' "$CACHE")" = "0" ]
  jq -S 'del(.checkedAt)' "$CACHE" >"$BATS_TEST_TMPDIR/actual"
  cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual"
}

# seed_cache <mode>: write the fixture cache the mode's cases start from.
seed_cache() {
  case "$1" in
    deps | gaia) write_populated_cache ;;
    pull) write_cache_behind_origin ;;
    fitness) write_cache_with_fitness_fields ;;
  esac
}

# run_mode <mode>: run the bust for the mode, with the version a pull needs.
run_mode() {
  if [ "$1" = "pull" ]; then
    run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4
  else
    run bash "$BUST" --cache "$CACHE" --mode "$1"
  fi
}

# temp_file_count: leftover bust temp files beside the cache.
temp_file_count() {
  find "$BATS_TEST_TMPDIR" -name '.update-check-bust.*' | wc -l | tr -d ' '
}

@test "the rewrite leaves no temp file beside the cache (deps, pull, fitness)" {
  local mode
  for mode in deps pull fitness; do
    seed_cache "$mode"
    run_mode "$mode"
    [ "$status" -eq 0 ] || { echo "case $mode: status $status" >&2; return 1; }
    [ -f "$CACHE" ] || { echo "case $mode: cache file gone" >&2; return 1; }
    [ "$(temp_file_count)" = "0" ] || { echo "case $mode: temp file left behind" >&2; return 1; }
  done
}

@test "an absent cache exits 0 SKIPPED no cache and creates nothing (deps, pull, fitness)" {
  local mode
  for mode in deps pull fitness; do
    rm -f "$CACHE"
    run_mode "$mode"
    [ "$status" -eq 0 ] || { echo "case $mode: status $status" >&2; return 1; }
    [ "$output" = "SKIPPED no cache" ] || { echo "case $mode: output [$output]" >&2; return 1; }
    [ ! -e "$CACHE" ] || { echo "case $mode: cache created" >&2; return 1; }
    [ "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -type f | wc -l | tr -d ' ')" = "0" ] || { echo "case $mode: a file was created" >&2; return 1; }
  done
}

@test "BUST_FAILED exits 3 and leaves the file bytes unchanged (unparseable, non-object, no jq)" {
  local case_name tool_directory tool
  for case_name in deps-unparseable deps-not-object deps-no-jq fitness-unparseable fitness-not-object; do
    rm -f "$CACHE"
    case "$case_name" in
      deps-unparseable) printf '{"outdatedCount": 7,, nope' >"$CACHE" ;;
      deps-not-object) printf 'null
' >"$CACHE" ;;
      deps-no-jq) write_populated_cache ;;
      fitness-unparseable) printf 'not json{' >"$CACHE" ;;
      fitness-not-object) printf '[1,2]' >"$CACHE" ;;
    esac
    cp "$CACHE" "$BATS_TEST_TMPDIR/original"
    case "$case_name" in
      deps-no-jq)
        tool_directory="$BATS_TEST_TMPDIR/tools"
        mkdir -p "$tool_directory"
        for tool in date mktemp mv rm; do
          [ -e "$tool_directory/$tool" ] || ln -s "$(command -v "$tool")" "$tool_directory/$tool"
        done
        [ ! -e "$tool_directory/jq" ] || { echo "case $case_name: jq is on the stripped PATH" >&2; return 1; }
        run env PATH="$tool_directory" "$(command -v bash)" "$BUST" --cache "$CACHE" --mode deps ;;
      fitness-*) run bash "$BUST" --cache "$CACHE" --mode fitness ;;
      *) run bash "$BUST" --cache "$CACHE" --mode deps ;;
    esac
    [ "$status" -eq 3 ] || { echo "case $case_name: status $status" >&2; return 1; }
    case "$output" in BUST_FAILED*) ;; *) echo "case $case_name: output [$output]" >&2; return 1 ;; esac
    cmp "$CACHE" "$BATS_TEST_TMPDIR/original" || { echo "case $case_name: file bytes changed" >&2; return 1; }
    [ "$(temp_file_count)" = "0" ] || { echo "case $case_name: temp file left behind" >&2; return 1; }
  done
}

@test "usage errors exit 2 and leave the file unchanged" {
  local case_name version
  local -a arguments
  for case_name in relative-cache missing-cache unknown-mode gaia-no-version drop-claim-non-numeric drop-claim-deps \
    pull-version-2.0 pull-version-latest pull-version-2.0.4.1 pull-version-v2.0.4 pull-version- \
    pull-drop-claim fitness-version fitness-drop-claim; do
    rm -f "$CACHE"
    case "$case_name" in
      relative-cache) write_populated_cache; arguments=(--cache relative/update-check.json --mode deps) ;;
      missing-cache) write_populated_cache; arguments=(--mode deps) ;;
      unknown-mode) write_populated_cache; arguments=(--cache "$CACHE" --mode other) ;;
      gaia-no-version) write_populated_cache; arguments=(--cache "$CACHE" --mode gaia) ;;
      drop-claim-non-numeric) write_cache_with_claims; arguments=(--cache "$CACHE" --mode gaia --version 2.0.0 --drop-claim abc) ;;
      drop-claim-deps) write_cache_with_claims; arguments=(--cache "$CACHE" --mode deps --drop-claim 42) ;;
      pull-version-*)
        version="${case_name#pull-version-}"
        write_cache_behind_origin
        arguments=(--cache "$CACHE" --mode pull --version "$version") ;;
      pull-drop-claim) write_cache_behind_origin; arguments=(--cache "$CACHE" --mode pull --version 2.0.4 --drop-claim 41) ;;
      fitness-version) write_cache_with_fitness_fields; arguments=(--cache "$CACHE" --mode fitness --version 2.0.4) ;;
      fitness-drop-claim) write_cache_with_fitness_fields; arguments=(--cache "$CACHE" --mode fitness --drop-claim 12) ;;
    esac
    cp "$CACHE" "$BATS_TEST_TMPDIR/original"
    run bash "$BUST" "${arguments[@]}"
    [ "$status" -eq 2 ] || { echo "case $case_name: status $status" >&2; return 1; }
    cmp "$CACHE" "$BATS_TEST_TMPDIR/original" || { echo "case $case_name: file bytes changed" >&2; return 1; }
  done
}

@test "pull sets gaiaCurrent/gaiaOriginVersion, keeps gaiaHasUpdate for a newer latest, clears it when latest is pulled, zeroes checkedAt" {
  write_cache_behind_origin
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4
  [ "$status" -eq 0 ] || { echo "case newer latest: status $status" >&2; return 1; }
  [ "$output" = "BUSTED" ] || { echo "case newer latest: output [$output]" >&2; return 1; }
  [ "$(jq -r '.gaiaCurrent' "$CACHE")" = "2.0.4" ] || { echo "case gaiaCurrent: not the version" >&2; return 1; }
  [ "$(jq -r '.gaiaOriginVersion' "$CACHE")" = "2.0.4" ] || { echo "case gaiaOriginVersion: not the version" >&2; return 1; }
  [ "$(jq '.gaiaHasUpdate' "$CACHE")" = "true" ] || { echo "case newer latest: gaiaHasUpdate not kept" >&2; return 1; }
  [ "$(jq -r '.gaiaLatest' "$CACHE")" = "2.0.5" ] || { echo "case newer latest: gaiaLatest touched" >&2; return 1; }
  [ "$(jq '.checkedAt' "$CACHE")" = "0" ] || { echo "case checkedAt: not zeroed" >&2; return 1; }

  write_cache_behind_origin
  jq '.gaiaLatest = "2.0.4"' "$CACHE" >"$BATS_TEST_TMPDIR/edited"
  cp "$BATS_TEST_TMPDIR/edited" "$CACHE"
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4
  [ "$status" -eq 0 ] || { echo "case latest pulled: status $status" >&2; return 1; }
  [ "$(jq '.gaiaHasUpdate' "$CACHE")" = "false" ] || { echo "case latest pulled: gaiaHasUpdate not cleared" >&2; return 1; }
}
