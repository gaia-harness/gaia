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
