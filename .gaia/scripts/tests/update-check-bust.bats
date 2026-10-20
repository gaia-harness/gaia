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

@test "a cache missing the keys still receives them" {
  printf '{"codifyReviewCount": 1}\n' >"$CACHE"
  run bash "$BUST" --cache "$CACHE" --mode deps
  [ "$status" -eq 0 ]
  [ "$(jq '.outdatedCount' "$CACHE")" = "0" ]
  [ "$(jq '.codifyReviewCount' "$CACHE")" = "1" ]
}

@test "the rewrite leaves no temp file beside the cache" {
  write_populated_cache
  run bash "$BUST" --cache "$CACHE" --mode deps
  [ "$status" -eq 0 ]
  [ "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name '.update-check-bust.*' | wc -l | tr -d ' ')" = "0" ]
}

@test "an absent cache exits 0 SKIPPED no cache and creates nothing" {
  run bash "$BUST" --cache "$CACHE" --mode deps
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED no cache" ]
  [ ! -e "$CACHE" ]
  [ "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -type f | wc -l | tr -d ' ')" = "0" ]
}

@test "unparseable JSON exits 3 BUST_FAILED and leaves the file's bytes unchanged" {
  printf '{"outdatedCount": 7,, nope' >"$CACHE"
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  run bash "$BUST" --cache "$CACHE" --mode deps
  [ "$status" -eq 3 ]
  case "$output" in BUST_FAILED*) ;; *) return 1 ;; esac
  cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
  [ "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name '.update-check-bust.*' | wc -l | tr -d ' ')" = "0" ]
}

@test "valid JSON that is not an object exits 3 BUST_FAILED and leaves the file unchanged" {
  printf 'null\n' >"$CACHE"
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  run bash "$BUST" --cache "$CACHE" --mode deps
  [ "$status" -eq 3 ]
  cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
}

@test "no jq on PATH exits 3 BUST_FAILED and leaves the file unchanged" {
  write_populated_cache
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  local tool_directory="$BATS_TEST_TMPDIR/tools" tool
  mkdir -p "$tool_directory"
  for tool in date mktemp mv rm; do
    ln -s "$(command -v "$tool")" "$tool_directory/$tool"
  done
  [ ! -e "$tool_directory/jq" ]
  run env PATH="$tool_directory" "$(command -v bash)" "$BUST" --cache "$CACHE" --mode deps
  [ "$status" -eq 3 ]
  case "$output" in BUST_FAILED*) ;; *) return 1 ;; esac
  cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
}

@test "a relative --cache exits 2" {
  run bash "$BUST" --cache relative/update-check.json --mode deps
  [ "$status" -eq 2 ]
}

@test "a missing --cache exits 2" {
  run bash "$BUST" --mode deps
  [ "$status" -eq 2 ]
}

@test "an unknown --mode exits 2" {
  write_populated_cache
  run bash "$BUST" --cache "$CACHE" --mode other
  [ "$status" -eq 2 ]
}

@test "gaia with no --version exits 2 and leaves the file unchanged" {
  write_populated_cache
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  run bash "$BUST" --cache "$CACHE" --mode gaia
  [ "$status" -eq 2 ]
  cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
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

@test "--drop-claim leaves a missing or malformed gaiaUpdateClaims alone" {
  write_populated_cache
  run bash "$BUST" --cache "$CACHE" --mode gaia --version 2.0.0 --drop-claim 42
  [ "$status" -eq 0 ]
  [ "$(jq 'has("gaiaUpdateClaims")' "$CACHE")" = "false" ]
  jq '.gaiaUpdateClaims = "oops"' "$CACHE" >"$BATS_TEST_TMPDIR/malformed"
  cp "$BATS_TEST_TMPDIR/malformed" "$CACHE"
  run bash "$BUST" --cache "$CACHE" --mode gaia --version 2.0.0 --drop-claim 42
  [ "$status" -eq 0 ]
  [ "$(jq -r '.gaiaUpdateClaims' "$CACHE")" = "oops" ]
}

@test "--drop-claim with a non-numeric value exits 2 and leaves the file unchanged" {
  write_cache_with_claims
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  run bash "$BUST" --cache "$CACHE" --mode gaia --version 2.0.0 --drop-claim abc
  [ "$status" -eq 2 ]
  cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
}

@test "--drop-claim with --mode deps exits 2 and leaves the file unchanged" {
  write_cache_with_claims
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  run bash "$BUST" --cache "$CACHE" --mode deps --drop-claim 42
  [ "$status" -eq 2 ]
  cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
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

@test "pull sets gaiaCurrent and gaiaOriginVersion to the version" {
  write_cache_behind_origin
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4
  [ "$status" -eq 0 ]
  [ "$output" = "BUSTED" ]
  [ "$(jq -r '.gaiaCurrent' "$CACHE")" = "2.0.4" ]
  [ "$(jq -r '.gaiaOriginVersion' "$CACHE")" = "2.0.4" ]
}

@test "pull keeps a newer release visible: gaiaHasUpdate true and gaiaLatest untouched" {
  write_cache_behind_origin
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4
  [ "$status" -eq 0 ]
  [ "$(jq '.gaiaHasUpdate' "$CACHE")" = "true" ]
  [ "$(jq -r '.gaiaLatest' "$CACHE")" = "2.0.5" ]
}

@test "pull clears gaiaHasUpdate when gaiaLatest is the pulled version" {
  write_cache_behind_origin
  jq '.gaiaLatest = "2.0.4"' "$CACHE" >"$BATS_TEST_TMPDIR/edited"
  cp "$BATS_TEST_TMPDIR/edited" "$CACHE"
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4
  [ "$status" -eq 0 ]
  [ "$(jq '.gaiaHasUpdate' "$CACHE")" = "false" ]
}

@test "pull zeroes checkedAt so the next render refreshes" {
  write_cache_behind_origin
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4
  [ "$status" -eq 0 ]
  [ "$(jq '.checkedAt' "$CACHE")" = "0" ]
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

@test "pull replaces the cache file and leaves no temp file behind" {
  write_cache_behind_origin
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  [ "$(find "$BATS_TEST_TMPDIR" -name '.update-check-bust.*' | wc -l | tr -d ' ')" = "0" ]
}

@test "pull on a missing cache prints SKIPPED no cache and creates nothing" {
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED no cache" ]
  [ ! -e "$CACHE" ]
}

@test "pull rejects a version that is not x.y.z and leaves the cache byte-identical" {
  local bad_version
  write_cache_behind_origin
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  for bad_version in 2.0 latest 2.0.4.1 v2.0.4 ''; do
    run bash "$BUST" --cache "$CACHE" --mode pull --version "$bad_version"
    [ "$status" -eq 2 ]
    cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
  done
}

@test "pull accepts a prerelease version" {
  write_cache_behind_origin
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4-rc.1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.gaiaCurrent' "$CACHE")" = "2.0.4-rc.1" ]
}

@test "pull with --drop-claim exits 2" {
  write_cache_behind_origin
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  run bash "$BUST" --cache "$CACHE" --mode pull --version 2.0.4 --drop-claim 41
  [ "$status" -eq 2 ]
  cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
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

@test "fitness replaces the cache file and leaves no temp file behind" {
  write_cache_with_fitness_fields
  run bash "$BUST" --cache "$CACHE" --mode fitness
  [ "$status" -eq 0 ]
  [ "$(find "$BATS_TEST_TMPDIR" -name '.update-check-bust.*' | wc -l | tr -d ' ')" = "0" ]
}

@test "fitness with --version exits 2 and leaves the cache byte-identical" {
  write_cache_with_fitness_fields
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  run bash "$BUST" --cache "$CACHE" --mode fitness --version 2.0.4
  [ "$status" -eq 2 ]
  cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
}

@test "fitness with --drop-claim exits 2 and leaves the cache byte-identical" {
  write_cache_with_fitness_fields
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  run bash "$BUST" --cache "$CACHE" --mode fitness --drop-claim 12
  [ "$status" -eq 2 ]
  cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
}

@test "fitness on a missing cache prints SKIPPED no cache and creates nothing" {
  run bash "$BUST" --cache "$CACHE" --mode fitness
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED no cache" ]
  [ ! -e "$CACHE" ]
}

@test "fitness on unparsable JSON exits 3 BUST_FAILED and leaves no temp file" {
  printf 'not json{' >"$CACHE"
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  run bash "$BUST" --cache "$CACHE" --mode fitness
  [ "$status" -eq 3 ]
  case "$output" in BUST_FAILED*) ;; *) return 1 ;; esac
  cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
  [ "$(find "$BATS_TEST_TMPDIR" -name '.update-check-bust.*' | wc -l | tr -d ' ')" = "0" ]
}

@test "fitness on a non-object exits 3 BUST_FAILED and leaves the cache unchanged" {
  printf '[1,2]' >"$CACHE"
  cp "$CACHE" "$BATS_TEST_TMPDIR/original"
  run bash "$BUST" --cache "$CACHE" --mode fitness
  [ "$status" -eq 3 ]
  cmp "$CACHE" "$BATS_TEST_TMPDIR/original"
}
