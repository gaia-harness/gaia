#!/usr/bin/env bats
#
# Suite for .gaia/scripts/context-checkpoint-lib.sh: the checkpoint line, the
# bands, the override (its range, clamps and off switch), the context
# file writer and reader, and the session id guard.
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
@test "override: a value past the maximum clamps to the maximum and the window share stays internal" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":900000,"ask_window_pct":90}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "$GAIA_CONTEXT_ASK_TOKENS_MAXIMUM $GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT" ]
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
  for value in 300000 200000 400000; do
    [ "$(grep -c "$value" "$library")" = "1" ]
  done
  [ "$(grep -c '^GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT=50$' "$library")" = "1" ]
  [ "$(grep -c '^GAIA_CONTEXT_YELLOW_WINDOW_PERCENT=30$' "$library")" = "1" ]
  # No numeric literal other than 100 / 0 / 1 / 2 in code lines past the constants block.
  run bash -c 'sed -n "/^_GAIA_CONTEXT_SKEW_SECONDS/,\$p" "$1" | grep -v "^ *#" | grep -nE "(^|[^0-9a-zA-Z_.-])(300000|200000|400000|50|30)([^0-9]|$)"' _ "$library"
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

  echo "case: effective_line: an in-range override wins, a raised one clamps, and 0 is off"
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":200000}}'
  run gaia_context_effective_line "$MAIN" 1000000
  [ "$output" = "200000" ]
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":900000}}'
  run gaia_context_effective_line "$MAIN" 1000000
  [ "$output" = "400000" ]
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":0}}'
  run gaia_context_effective_line "$MAIN" 1000000
  [ "$output" = "0" ]

  echo "case: effective_line: the half-window cap applies after the clamp"
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":400000}}'
  run gaia_context_effective_line "$MAIN" 200000
  [ "$output" = "100000" ]
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

  echo "case: the range ends on a 1M window"
  run gaia_context_bands 1000000 200000
  [ "$output" = "166666 200000 250000 300000" ]
  run gaia_context_bands 1000000 400000
  [ "$output" = "300000 400000 500000 600000" ]

  echo "case: yellow sits below red across the range, on a large and a small window"
  local window line yellow red rest
  for window in 1000000 200000; do
    for line in 200000 250000 300000 350000 400000; do
      line=$(gaia_context_line "$window" "$line" "$GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT")
      read -r yellow red rest <<<"$(gaia_context_bands "$window" "$line")"
      [ "$yellow" -lt "$red" ] || return 1
    done
  done

  echo "case: a zero line (checkpoint off) has no bands"
  run gaia_context_bands 1000000 0
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run gaia_context_band 500000 1000000 0
  [ "$status" -eq 1 ]
  [ -z "$output" ]
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

# expect_state <label> <settings json, or - for no file> <expected state line>:
# one row of the override table, through the state the warnings key off.
expect_state() {
  echo "case: $1"
  rm -f "$MAIN/.gaia/local/protected/checkpoint-override.json" "$(old_override_file)"
  [ "$2" = "-" ] || write_settings "$2"
  run gaia_context_override_state "$MAIN"
  [ "$output" = "$3" ]
}

@test "override reads: the range, the clamps, off, and invalid" {
  expect_override "no file reads the defaults" - "300000 50"
  expect_override "an in-range ask_tokens is honoured" \
    '{"version":1,"context_checkpoint":{"ask_tokens":250000}}' "250000 50"
  expect_override "ask_window_pct is not read" \
    '{"version":1,"context_checkpoint":{"ask_window_pct":20}}' "300000 50"

  expect_state "no file is absent" - "absent 300000 -"
  expect_state "no context_checkpoint is absent" '{"version":1}' "absent 300000 -"
  expect_state "no ask_tokens is absent" '{"version":1,"context_checkpoint":{"ask_window_pct":20}}' "absent 300000 -"
  expect_state "the minimum is accepted" '{"version":1,"context_checkpoint":{"ask_tokens":200000}}' "ok 200000 200000"
  expect_state "the maximum is accepted" '{"version":1,"context_checkpoint":{"ask_tokens":400000}}' "ok 400000 400000"
  expect_state "one below the minimum clamps up" '{"version":1,"context_checkpoint":{"ask_tokens":199999}}' "clamped-low 200000 199999"
  expect_state "1 clamps up" '{"version":1,"context_checkpoint":{"ask_tokens":1}}' "clamped-low 200000 1"
  expect_state "one above the maximum clamps down" '{"version":1,"context_checkpoint":{"ask_tokens":400001}}' "clamped-high 400000 400001"
  expect_state "0 is off" '{"version":1,"context_checkpoint":{"ask_tokens":0}}' "off 0 0"
  expect_state "a string is invalid" '{"version":1,"context_checkpoint":{"ask_tokens":"abc"}}' "invalid 300000 -"
  expect_state "a negative is invalid" '{"version":1,"context_checkpoint":{"ask_tokens":-1}}' "invalid 300000 -"
  expect_state "a fraction is invalid" '{"version":1,"context_checkpoint":{"ask_tokens":1.5}}' "invalid 300000 -"
  expect_state "version 2 is invalid" '{"version":2,"context_checkpoint":{"ask_tokens":250000}}' "invalid 300000 -"
  expect_state "bad JSON is invalid" '{not json' "invalid 300000 -"
  expect_state "two JSON values are invalid" '{"version":1}{"version":1}' "invalid 300000 -"
  expect_state "a non-object context_checkpoint is invalid" '{"version":1,"context_checkpoint":5}' "invalid 300000 -"

  echo "case: with files at both locations only the protected one counts"
  rm -f "$MAIN/.gaia/local/protected/checkpoint-override.json"
  write_old_override '{"version":1,"context_checkpoint":{"ask_tokens":100000}}'
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":250000}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "250000 50" ]
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
  run env PATH= "$BASH" -c '. "$1"; for function_name in gaia_context_is_session_id gaia_context_file gaia_context_override gaia_context_override_state gaia_context_line gaia_context_bands gaia_context_write gaia_context_read gaia_context_effective_line gaia_context_band gaia_context_summary; do [ "$(type -t "$function_name")" = function ] || exit 1; done' _ "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  [ "$status" -eq 0 ]

  echo "case: double sourcing is harmless"
  run "$BASH" -c '. "$1"; . "$1"; echo "$GAIA_CONTEXT_UNIT_ROUNDS"' _ "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "band: 200k window edges, an override at the minimum, and off" {
  echo "case: 200k window edges with no override"
  run band_at 59999 200000
  [ "$output" = "green" ]
  run band_at 60000 200000
  [ "$output" = "yellow" ]
  run band_at 99999 200000
  [ "$output" = "yellow" ]
  run band_at 100000 200000
  [ "$output" = "red" ]

  echo "case: an override at the minimum keeps yellow below red"
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":200000}}'
  run band_at 166665 1000000
  [ "$output" = "green" ]
  run band_at 166666 1000000
  [ "$output" = "yellow" ]
  run band_at 199999 1000000
  [ "$output" = "yellow" ]
  run band_at 200000 1000000
  [ "$output" = "red" ]
  run band_at 249999 1000000
  [ "$output" = "red" ]
  run band_at 250000 1000000
  [ "$output" = "fire" ]
  run band_at 300000 1000000
  [ "$output" = "skull" ]

  echo "case: off has no band at any reading"
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":0}}'
  run band_at 900000 1000000
  [ "$status" -eq 1 ]
  [ -z "$output" ]
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
