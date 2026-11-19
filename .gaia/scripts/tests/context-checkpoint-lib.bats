#!/usr/bin/env bats
#
# Suite for .gaia/scripts/context-checkpoint-lib.sh: the checkpoint line, the
# bands, the lower-only override, the context file writer and reader, and the
# session id guard.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/context-checkpoint-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIBRARY_DIRECTORY="${CONTEXT_LIBRARY_DIRECTORY:-$REPO_ROOT/.gaia/scripts}"
  # shellcheck source=/dev/null
  . "$LIBRARY_DIRECTORY/context-checkpoint-lib.sh"
  MAIN="$BATS_TEST_TMPDIR/main"
  mkdir -p "$MAIN/.gaia/local/protected"
  SESSION_ID="12345678-1234-1234-1234-123456789abc"
}

write_settings() {
  printf '%s\n' "$1" >"$MAIN/.gaia/local/protected/checkpoint-override.json"
}

context_file() {
  gaia_context_file "$MAIN" "$SESSION_ID"
}

# put_context <json>: write a raw context file.
put_context() {
  local file_path
  file_path="$(context_file)"
  mkdir -p "${file_path%/*}"
  printf '%s' "$1" >"$file_path"
}

context_json() {
  printf '{"version":%s,"session_id":"%s","used_percentage":10,"used_tokens":100000,"context_window_size":1000000,"written_at":%s}' "$1" "$SESSION_ID" "$2"
}

# write_old_override <json>: a file at the retired location, which nothing reads.
old_override_file() { printf '%s/.gaia/local/checkpoint-override.json\n' "$MAIN"; }

write_old_override() {
  printf '%s\n' "$1" >"$(old_override_file)"
}

@test "override: a file only at the retired location reads the defaults" {
  write_old_override '{"version":1,"context_checkpoint":{"ask_tokens":100000}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

# bats test_tags=protected
@test "override: lower-only guard, a raised override never becomes the effective value" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":900000,"ask_window_pct":90}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT $GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT" ]
}

@test "write then read: a fresh reading round-trips" {
  gaia_context_write "$MAIN" "$SESSION_ID" 25.5 255000 1000000 1700000000
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 0 ]
  [ "$output" = "fresh 255000 1000000" ]
  run jq -e '.version == 1 and .session_id == "'"$SESSION_ID"'" and .used_percentage == 25.5 and .used_tokens == 255000 and .context_window_size == 1000000 and .written_at == 1700000000' "$(context_file)"
  [ "$status" -eq 0 ]
  run find "$MAIN/.gaia/local/cache/shared/context" -name '*.tmp.*'
  [ -z "$output" ]
}

@test "constants: each numeric value is defined once and no function body inlines one" {
  local library="$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh" value
  for value in 300000 250000; do
    [ "$(grep -c "$value" "$library")" = "1" ]
  done
  [ "$(grep -c '^GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT=50$' "$library")" = "1" ]
  [ "$(grep -c '^GAIA_CONTEXT_YELLOW_WINDOW_PERCENT=30$' "$library")" = "1" ]
  # No numeric literal other than 100 / 0 / 1 / 2 in code lines past the constants block.
  run bash -c 'sed -n "/^_GAIA_CONTEXT_SKEW_SECONDS/,\$p" "$1" | grep -v "^ *#" | grep -nE "(^|[^0-9a-zA-Z_.-])(300000|250000|50|30)([^0-9]|$)"' _ "$library"
  [ "$status" -eq 1 ]
}

# band_at <used> <window>: the band for a reading under the lib's effective line on the scratch main root.
band_at() {
  local line
  line=$(gaia_context_effective_line "$MAIN" "$2") || return 2
  gaia_context_band "$1" "$2" "$line"
}

@test "band: 1M window edges with no override" {
  local reading expected
  for reading in "249999 green" "250000 yellow" "299999 yellow" "300000 red" "374999 red" "375000 fire" "449999 fire" "450000 skull"; do
    read -r reading expected <<<"$reading"
    run band_at "$reading" 1000000
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
  done
}

@test "checkpoint line and effective line" {
  echo "case: line: tokens cap on a large window"
  run gaia_context_line 1000000 300000 50
  [ "$status" -eq 0 ]
  [ "$output" = "300000" ]

  echo "case: line: percent cap on a small window"
  run gaia_context_line 200000 300000 50
  [ "$output" = "100000" ]

  echo "case: line: a lowered ask_tokens wins"
  run gaia_context_line 1000000 200000 50
  [ "$output" = "200000" ]

  echo "case: effective_line: no override reads the default cap"
  run gaia_context_effective_line "$MAIN" 1000000
  [ "$status" -eq 0 ]
  [ "$output" = "300000" ]
  run gaia_context_effective_line "$MAIN" 200000
  [ "$output" = "100000" ]

  echo "case: effective_line: a lowered override wins and a raised one does not"
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":200000}}'
  run gaia_context_effective_line "$MAIN" 1000000
  [ "$output" = "200000" ]
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":900000}}'
  run gaia_context_effective_line "$MAIN" 1000000
  [ "$output" = "300000" ]
}

@test "rc 2 on a non-integer or empty argument" {
  echo "case: line: a non-integer or empty argument is rc 2"
  run gaia_context_line abc 300000 50
  [ "$status" -eq 2 ]
  run gaia_context_line 1000000 "" 50
  [ "$status" -eq 2 ]

  echo "case: bands: a bad argument is rc 2"
  run gaia_context_bands 1000000 x
  [ "$status" -eq 2 ]

  echo "case: effective_line: a non-integer window is rc 2"
  run gaia_context_effective_line "$MAIN" abc
  [ "$status" -eq 2 ]
  run gaia_context_effective_line "$MAIN" ""
  [ "$status" -eq 2 ]

  echo "case: band: a bad argument is rc 2"
  run gaia_context_band abc 1000000 300000
  [ "$status" -eq 2 ]
  run gaia_context_band 100 abc 300000
  [ "$status" -eq 2 ]
  run gaia_context_band 100 1000000 ""
  [ "$status" -eq 2 ]
  run gaia_context_band "" 1000000 300000
  [ "$status" -eq 2 ]

  echo "case: summary: a non-integer argument is rc 2 and prints nothing"
  run gaia_context_summary abc 1000000
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run gaia_context_summary 100 1.5
  [ "$status" -eq 2 ]
  run gaia_context_summary 100 ""
  [ "$status" -eq 2 ]
}

@test "bands per window size" {
  echo "case: 1M window"
  run gaia_context_bands 1000000 300000
  [ "$output" = "250000 300000 375000 450000" ]

  echo "case: 200K window"
  run gaia_context_bands 200000 100000
  [ "$output" = "60000 100000 125000 150000" ]

  echo "case: yellow clamps to red"
  run gaia_context_bands 1000000 200000
  [ "$output" = "200000 200000 250000 300000" ]

  echo "case: yellow clamps to a line between the yellow cap and the default"
  run gaia_context_bands 1000000 280000
  [ "$output" = "250000 280000 350000 420000" ]
  run gaia_context_bands 1000000 240000
  [ "$output" = "240000 240000 300000 360000" ]
}

# expect_override <label> <settings json, or - for no file> <expected "tokens pct">:
# one row of the override table, each starting from a clean settings location.
expect_override() {
  echo "case: $1"
  rm -f "$MAIN/.gaia/local/protected/checkpoint-override.json" "$(old_override_file)"
  [ "$2" = "-" ] || write_settings "$2"
  run gaia_context_override "$MAIN"
  [ "$output" = "$3" ]
}

@test "override reads: lower honoured, everything else reads the default" {
  expect_override "no file reads the defaults" - "300000 50"
  expect_override "a file only at protected/checkpoint-override.json is honoured" \
    '{"version":1,"context_checkpoint":{"ask_tokens":150000}}' "150000 50"
  expect_override "a lower ask_tokens is honoured" \
    '{"version":1,"context_checkpoint":{"ask_tokens":200000}}' "200000 50"
  expect_override "a raised ask_tokens reads as the default" \
    '{"version":1,"context_checkpoint":{"ask_tokens":600000}}' "300000 50"
  expect_override "a string ask_tokens reads as the default" \
    '{"version":1,"context_checkpoint":{"ask_tokens":"abc"}}' "300000 50"
  expect_override "zero ask_tokens reads as the default" \
    '{"version":1,"context_checkpoint":{"ask_tokens":0}}' "300000 50"
  expect_override "negative ask_tokens reads as the default" \
    '{"version":1,"context_checkpoint":{"ask_tokens":-1}}' "300000 50"
  expect_override "fractional ask_tokens reads as the default" \
    '{"version":1,"context_checkpoint":{"ask_tokens":1.5}}' "300000 50"
  expect_override "a raised ask_window_pct reads as the default pct" \
    '{"version":1,"context_checkpoint":{"ask_window_pct":150}}' "300000 50"
  expect_override "a lowered ask_window_pct is honoured" \
    '{"version":1,"context_checkpoint":{"ask_window_pct":20}}' "300000 20"
  expect_override "version 2 reads as the defaults" \
    '{"version":2,"context_checkpoint":{"ask_tokens":100000}}' "300000 50"
  expect_override "invalid JSON reads as the defaults" '{not json' "300000 50"
  expect_override "a non-object context_checkpoint reads as the defaults" \
    '{"version":1,"context_checkpoint":5}' "300000 50"

  echo "case: with files at both locations only the protected one counts"
  rm -f "$MAIN/.gaia/local/protected/checkpoint-override.json"
  write_old_override '{"version":1,"context_checkpoint":{"ask_tokens":100000}}'
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":150000}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "150000 50" ]
}

@test "write refuses bad input and a bad session id creates no file" {
  echo "case: write: non-integer tokens or window write nothing"
  run gaia_context_write "$MAIN" "$SESSION_ID" 10 abc 1000000 1700000000
  [ "$status" -ne 0 ]
  run gaia_context_write "$MAIN" "$SESSION_ID" 10 100 1.5 1700000000
  [ "$status" -ne 0 ]
  [ ! -e "$(context_file)" ]

  echo "case: session id: a bad id is refused and creates no file"
  local bad
  for bad in "../../etc" "" "12345678-1234-1234-1234-123456789ab"; do
    run gaia_context_file "$MAIN" "$bad"
    [ "$status" -ne 0 ]
    run gaia_context_write "$MAIN" "$bad" 10 100 1000000 1700000000
    [ "$status" -ne 0 ]
  done
  [ ! -e "$MAIN/.gaia/local/cache" ]
  [ ! -e "$MAIN/.gaia/etc" ]
}

@test "read classifies a reading: fresh, missing, stale, future, unparseable" {
  echo "case: missing is rc 1"
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "missing" ]

  echo "case: a 31 minute old reading is stale"
  put_context "$(context_json 1 $((1700000000 - 1860)))"
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "stale" ]

  echo "case: a reading 10 minutes in the future is future"
  put_context "$(context_json 1 $((1700000000 + 600)))"
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "future" ]

  echo "case: a small clock skew is still fresh"
  put_context "$(context_json 1 $((1700000000 + 30)))"
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 0 ]
  [ "$output" = "fresh 100000 1000000" ]

  echo "case: garbage bytes are unparseable"
  put_context 'garbage bytes {{{'
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "unparseable" ]

  echo "case: version 2 is unparseable"
  put_context "$(context_json 2 1700000000)"
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "unparseable" ]

  echo "case: a non-integer field is unparseable"
  put_context '{"version":1,"used_tokens":"x","context_window_size":1000000,"written_at":1700000000}'
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "unparseable" ]
}

@test "sourcing is safe: empty PATH and twice" {
  echo "case: succeeds with an empty PATH and defines every function"
  run env PATH= "$BASH" -c '. "$1"; for function_name in gaia_context_is_session_id gaia_context_file gaia_context_override gaia_context_line gaia_context_bands gaia_context_write gaia_context_read gaia_context_effective_line gaia_context_band gaia_context_summary; do [ "$(type -t "$function_name")" = function ] || exit 1; done' _ "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  [ "$status" -eq 0 ]

  echo "case: double sourcing is harmless"
  run "$BASH" -c '. "$1"; . "$1"; echo "$GAIA_CONTEXT_UNIT_ROUNDS"' _ "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "band: 200k window edges, and a lowered override drops the yellow band" {
  echo "case: 200k window edges with no override"
  run band_at 59999 200000
  [ "$output" = "green" ]
  run band_at 60000 200000
  [ "$output" = "yellow" ]
  run band_at 99999 200000
  [ "$output" = "yellow" ]
  run band_at 100000 200000
  [ "$output" = "red" ]

  echo "case: a lowered override line has no yellow band"
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":200000}}'
  run band_at 199999 1000000
  [ "$output" = "green" ]
  run band_at 200000 1000000
  [ "$output" = "red" ]
  run band_at 249999 1000000
  [ "$output" = "red" ]
  run band_at 250000 1000000
  [ "$output" = "fire" ]
  run band_at 300000 1000000
  [ "$output" = "skull" ]
}

@test "summary text and unavailable window" {
  echo "case: format matches the audit loop option text"
  run gaia_context_summary 320000 1000000
  [ "$status" -eq 0 ]
  [ "$output" = "Context 32% (320k of 1000k)" ]
  run gaia_context_summary 450000 1000000
  [ "$output" = "Context 45% (450k of 1000k)" ]
  run gaia_context_summary 12345 200000
  [ "$output" = "Context 6% (12k of 200k)" ]

  echo "case: a zero window prints unavailable"
  run gaia_context_summary 100 0
  [ "$status" -eq 0 ]
  [ "$output" = "Context unavailable" ]
}
