#!/usr/bin/env bats
#
# Suite for the sub-agent additions to .gaia/scripts/context-checkpoint-lib.sh:
# the yield limit, the main session's window regardless of reading age, the
# window a sub-agent's bands use, and the token reading taken from the tail of
# a sub-agent transcript.
#
# Each mutant case runs a scratch copy of the lib (made in $BATS_TEST_TMPDIR)
# with one line changed and expects the matching case to go red, which proves
# the suite reads the constant or enforces the rule it names. Window values
# derive from the lib's constants; bound-sized fixtures are generated from the
# lib's byte bounds.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/context-checkpoint-subagent-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIBRARY_PATH="$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  # shellcheck source=/dev/null
  . "$LIBRARY_PATH"
  MAIN="$BATS_TEST_TMPDIR/main"
  mkdir -p "$MAIN"
  SESSION_ID="12345678-1234-1234-1234-123456789abc"
  TRANSCRIPT="$BATS_TEST_TMPDIR/agent.jsonl"
}

# put_context <version> <window> <written_at>: write the session's context file.
put_context() {
  local file_path
  file_path="$(gaia_context_file "$MAIN" "$SESSION_ID")"
  mkdir -p "${file_path%/*}"
  printf '{"version":%s,"session_id":"%s","used_percentage":10,"used_tokens":100000,"context_window_size":%s,"written_at":%s}' \
    "$1" "$SESSION_ID" "$2" "$3" >"$file_path"
}

# assistant_line <input> <creation> <read> <output>: one assistant record.
assistant_line() {
  printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_creation":{"ephemeral_5m_input_tokens":%s,"ephemeral_1h_input_tokens":0},"cache_read_input_tokens":%s,"output_tokens":%s,"service_tier":"standard"}}}\n' \
    "$1" "$2" "$2" "$3" "$4"
}

# filler_line <bytes>: one JSON line of roughly <bytes> bytes with no usage object.
filler_line() {
  printf '{"type":"user","message":"'
  head -c "$1" /dev/zero | tr '\0' 'x'
  printf '"}\n'
}

# long_record_line <pad_bytes>: one assistant record whose line is longer than <pad_bytes>.
long_record_line() {
  printf '{"type":"assistant","message":{"pad":"'
  head -c "$1" /dev/zero | tr '\0' 'x'
  printf '","usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000,"output_tokens":1}}}\n'
}

# mutant_library <sed-expression>: a scratch lib copy edited by sed; prints its path.
mutant_library() {
  local mutant="$BATS_TEST_TMPDIR/mutant-lib.sh"
  sed -e "$1" "$LIBRARY_PATH" >"$mutant"
  printf '%s\n' "$mutant"
}

# run_in_fresh_shell <lib> <function> <args...>: run a lib function in a clean bash.
run_in_fresh_shell() {
  local library="$1"
  shift
  run bash -c '. "$1"; shift; "$@"' _ "$library" "$@"
}

@test "yield limit prints the constant" {
  run gaia_context_yield_limit
  [ "$status" -eq 0 ]
  [ "$output" = "$GAIA_CONTEXT_YIELD_LIMIT" ]
}

@test "yield limit follows a changed constant (red twin)" {
  local mutant
  mutant="$(mutant_library 's/^GAIA_CONTEXT_YIELD_LIMIT=.*/GAIA_CONTEXT_YIELD_LIMIT=7/')"
  run_in_fresh_shell "$mutant" gaia_context_yield_limit
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
  [ "$output" != "$GAIA_CONTEXT_YIELD_LIMIT" ]
}

@test "last window prints the window of a fresh reading" {
  put_context "$GAIA_CONTEXT_FILE_VERSION" 500000 "$(date +%s)"
  run gaia_context_last_window "$MAIN" "$SESSION_ID"
  [ "$status" -eq 0 ]
  [ "$output" = "500000" ]
}

@test "last window ignores the age of the reading" {
  put_context "$GAIA_CONTEXT_FILE_VERSION" 500000 $(($(date +%s) - GAIA_CONTEXT_FRESH_SECONDS * 10))
  run gaia_context_last_window "$MAIN" "$SESSION_ID"
  [ "$status" -eq 0 ]
  [ "$output" = "500000" ]
}

@test "last window is rc 1 with empty stdout when the file is missing" {
  run gaia_context_last_window "$MAIN" "$SESSION_ID"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "last window is rc 1 with empty stdout for unparseable JSON" {
  local file_path
  file_path="$(gaia_context_file "$MAIN" "$SESSION_ID")"
  mkdir -p "${file_path%/*}"
  printf 'not json {' >"$file_path"
  run gaia_context_last_window "$MAIN" "$SESSION_ID"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "last window is rc 1 with empty stdout for a wrong version" {
  put_context $((GAIA_CONTEXT_FILE_VERSION + 1)) 500000 "$(date +%s)"
  run gaia_context_last_window "$MAIN" "$SESSION_ID"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "last window is rc 1 with empty stdout for a zero window" {
  put_context "$GAIA_CONTEXT_FILE_VERSION" 0 "$(date +%s)"
  run gaia_context_last_window "$MAIN" "$SESSION_ID"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "last window is rc 1 for a bad session id" {
  run gaia_context_last_window "$MAIN" "not-a-session"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "sub-agent window keeps the last window for a reading below it" {
  put_context "$GAIA_CONTEXT_FILE_VERSION" 500000 "$(date +%s)"
  run gaia_context_subagent_window "$MAIN" "$SESSION_ID" 499999
  [ "$status" -eq 0 ]
  [ "$output" = "500000" ]
}

@test "sub-agent window keeps the last window for a reading equal to it" {
  put_context "$GAIA_CONTEXT_FILE_VERSION" 500000 "$(date +%s)"
  run gaia_context_subagent_window "$MAIN" "$SESSION_ID" 500000
  [ "$status" -eq 0 ]
  [ "$output" = "500000" ]
}

@test "sub-agent window falls back to the default for a reading above the last window" {
  put_context "$GAIA_CONTEXT_FILE_VERSION" 500000 "$(date +%s)"
  run gaia_context_subagent_window "$MAIN" "$SESSION_ID" 500001
  [ "$status" -eq 0 ]
  [ "$output" = "$GAIA_CONTEXT_DEFAULT_WINDOW" ]
}

@test "sub-agent window prints the default with no reading file" {
  run gaia_context_subagent_window "$MAIN" "$SESSION_ID" 1000
  [ "$status" -eq 0 ]
  [ "$output" = "$GAIA_CONTEXT_DEFAULT_WINDOW" ]
}

@test "sub-agent window reads the default from the lib (red twin)" {
  local mutant
  mutant="$(mutant_library 's/^GAIA_CONTEXT_DEFAULT_WINDOW=.*/GAIA_CONTEXT_DEFAULT_WINDOW=123456/')"
  run_in_fresh_shell "$mutant" gaia_context_subagent_window "$MAIN" "$SESSION_ID" 1000
  [ "$status" -eq 0 ]
  [ "$output" = "123456" ]
  [ "$output" != "$GAIA_CONTEXT_DEFAULT_WINDOW" ]
}

@test "sub-agent window is rc 2 for a non-integer reading" {
  put_context "$GAIA_CONTEXT_FILE_VERSION" 500000 "$(date +%s)"
  run gaia_context_subagent_window "$MAIN" "$SESSION_ID" 12abc
  [ "$status" -eq 2 ]
  run gaia_context_subagent_window "$MAIN" "$SESSION_ID" ""
  [ "$status" -eq 2 ]
}

@test "transcript reading sums input, cache creation and cache read" {
  assistant_line 10 200 3000 40000 >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "3210" ]
}

@test "transcript reading takes the last assistant record" {
  {
    assistant_line 900 900 900 1
    assistant_line 10 200 3000 1
    filler_line 50
  } >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "3210" ]
}

@test "transcript reading rejects a first-match-from-the-start scan (red twin)" {
  local mutant
  {
    assistant_line 900 900 900 1
    assistant_line 10 200 3000 1
  } >"$TRANSCRIPT"
  # Prepending each candidate reverses the order, so the walk from the end meets the first record.
  # shellcheck disable=SC2016 # the sed text is matched literally, not expanded
  mutant="$(mutant_library 's/candidates+=("\$line")/candidates=("$line" ${candidates[@]+"${candidates[@]}"})/')"
  run_in_fresh_shell "$mutant" gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "2700" ]
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$output" = "3210" ]
}

@test "transcript reading skips a later line that has no usage record" {
  {
    assistant_line 10 200 3000 1
    printf '{"type":"assistant","message":{"role":"assistant","content":"no usage here"}}\n'
    filler_line 50
  } >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "3210" ]
}

@test "transcript reading finds the final record when the tail read starts mid-line" {
  local file_size
  {
    filler_line $((GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES * 2))
    assistant_line 900 900 900 1
    filler_line 100
    assistant_line 10 200 3000 1
  } >"$TRANSCRIPT"
  file_size=$(wc -c <"$TRANSCRIPT")
  [ "$file_size" -gt "$GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES" ]
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "3210" ]
}

@test "transcript reading never parses the partial first line of a read" {
  local long_pad=$((GAIA_CONTEXT_TRANSCRIPT_WIDE_BYTES + 1000))
  {
    filler_line 100
    long_record_line "$long_pad"
    filler_line 100
  } >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "transcript reading widens once for a final line longer than the tail bound" {
  local long_pad=$((GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES + 1000))
  {
    filler_line 100
    long_record_line "$long_pad"
  } >"$TRANSCRIPT"
  [ "$long_pad" -lt "$GAIA_CONTEXT_TRANSCRIPT_WIDE_BYTES" ]
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "3210" ]
}

@test "transcript reading is rc 1 when the only record is beyond the widened bound" {
  local long_pad=$((GAIA_CONTEXT_TRANSCRIPT_WIDE_BYTES + 1000))
  {
    filler_line 100
    long_record_line "$long_pad"
  } >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "transcript reading finds a record that only the widened read reaches" {
  {
    assistant_line 10 200 3000 1
    filler_line $((GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES + 5000))
  } >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "3210" ]
}

@test "transcript reading is rc 1 for a transcript with no assistant usage record" {
  {
    filler_line 100
    printf '{"type":"user","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}}}\n'
  } >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "transcript reading does not count a usage object inside an escaped string" {
  {
    assistant_line 10 200 3000 1
    printf '{"type":"user","message":{"content":"{\\"type\\":\\"assistant\\",\\"usage\\":{\\"input_tokens\\":9,\\"cache_creation_input_tokens\\":9,\\"cache_read_input_tokens\\":9}}"}}\n'
  } >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "3210" ]
}

@test "transcript reading does not count an escaped usage object on an assistant line" {
  printf '{"type":"assistant","message":{"content":"{\\"usage\\":{\\"input_tokens\\":9,\\"cache_creation_input_tokens\\":9,\\"cache_read_input_tokens\\":9}}"}}\n' >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 1 ]
}

@test "transcript reading takes the three keys from inside the usage object" {
  printf '{"type":"assistant","input_tokens":777,"message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000}},"cache_read_input_tokens":888}\n' >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "3210" ]
}

@test "transcript reading rejects a usage object missing one of the three keys" {
  printf '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":3000}},"cache_creation_input_tokens":200}\n' >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 1 ]
}

@test "transcript reading is rc 1 for a missing file" {
  run gaia_context_transcript_reading "$BATS_TEST_TMPDIR/absent.jsonl"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "transcript reading is rc 1 for an empty file" {
  : >"$TRANSCRIPT"
  run gaia_context_transcript_reading "$TRANSCRIPT"
  [ "$status" -eq 1 ]
}

@test "the new helper bodies spell no window or bound literal" {
  local bodies
  bodies="$(awk '/^_?gaia_context_(yield_limit|last_window|subagent_window|transcript_reading|tail_reading)\(\)/,/^}/' "$LIBRARY_PATH")"
  [ -n "$bodies" ]
  printf '%s\n' "$bodies" | grep -qwE "$GAIA_CONTEXT_DEFAULT_WINDOW|$GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES|$GAIA_CONTEXT_TRANSCRIPT_WIDE_BYTES" && return 1
  true
}
