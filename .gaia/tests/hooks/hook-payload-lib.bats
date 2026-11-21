#!/usr/bin/env bats

# Tests for .claude/hooks/lib/hook-payload.sh, the shared one-jq payload reader.
#
# The reader's claim is byte parity with the per-field `$(jq -r '.x // ""')`
# reads it replaces, one jq process per call, and a loud return 1 (never a
# misaligned field) on anything it cannot read. Each case drives one property.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/tests/hooks/hook-payload-lib.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  HOOK_PAYLOAD_LIBRARY="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.claude/hooks/lib/hook-payload.sh"
  # shellcheck disable=SC1090
  . "$HOOK_PAYLOAD_LIBRARY"
}

# assert_all_fields_empty: every exported global is "".
assert_all_fields_empty() {
  [ -z "$GAIA_HOOK_TOOL_NAME" ] || return 1
  [ -z "$GAIA_HOOK_EVENT" ] || return 1
  [ -z "$GAIA_HOOK_SESSION_ID" ] || return 1
  [ -z "$GAIA_HOOK_CWD" ] || return 1
  [ -z "$GAIA_HOOK_FILE_PATH" ] || return 1
  [ -z "$GAIA_HOOK_PATH" ] || return 1
  [ -z "$GAIA_HOOK_GLOB" ] || return 1
  [ -z "$GAIA_HOOK_COMMAND" ] || return 1
}

# command_from_payload <payload>: the legacy per-field read the reader replaces.
command_from_payload() {
  local value
  value=$(printf '%s' "$1" | jq -r '.tool_input.command // ""')
  printf '%s' "$value"
}

# all_fields: every exported global, "|"-joined in a fixed order (tool name,
# event, session id, cwd, file path, path, glob, command), so a row states all
# eight at once.
all_fields() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s' "$GAIA_HOOK_TOOL_NAME" "$GAIA_HOOK_EVENT" \
    "$GAIA_HOOK_SESSION_ID" "$GAIA_HOOK_CWD" "$GAIA_HOOK_FILE_PATH" \
    "$GAIA_HOOK_PATH" "$GAIA_HOOK_GLOB" "$GAIA_HOOK_COMMAND"
}

# check_field_rows <row>...: each row is label|payload|expected all_fields; the
# read must return 0 and set exactly the expected fields.
check_field_rows() {
  local row label rest payload expected actual
  for row in "$@"; do
    label=${row%%|*}; rest=${row#*|}
    payload=${rest%%|*}; expected=${rest#*|}
    gaia_hook_payload_read "$payload" || { echo "case $label: returned non-zero"; return 1; }
    actual=$(all_fields)
    [ "$actual" = "$expected" ] || { echo "case $label: want [$expected] got [$actual]"; return 1; }
  done
}

@test "every field is read from a PreToolUse Bash, Read, Grep and PostToolUse payload" {
  check_field_rows \
    'pre-tool-use-bash|{"session_id":"s-1","cwd":"/work/tree","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}|Bash|PreToolUse|s-1|/work/tree||||git status' \
    'read|{"session_id":"s-2","cwd":"/c","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}|Read|PreToolUse|s-2|/c|/etc/hosts|||' \
    'grep|{"session_id":"s-3","cwd":"/g","hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"x","path":"/src","glob":"*.ts"}}|Grep|PreToolUse|s-3|/g||/src|*.ts|' \
    'post-tool-use|{"session_id":"s-4","cwd":"/p","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"gh pr view 1"},"tool_response":{"stdout":"ok"}}|Bash|PostToolUse|s-4|/p||||gh pr view 1'
}

@test "a command round-trips byte for byte and trailing newlines are stripped" {
  local label payload expected legacy
  for label in edge-bytes trailing-newlines; do
    case "$label" in
      edge-bytes)
        expected=$'  line one\nsecond\tline with "double" and \'single\' quotes\x1fafter-separator  '
        payload=$(jq -cn --arg command "$expected" '{tool_name:"Bash",tool_input:{command:$command}}') ;;
      trailing-newlines)
        expected=$'first\nsecond'
        payload='{"tool_name":"Bash","tool_input":{"command":"first\nsecond\n\n"}}' ;;
    esac
    gaia_hook_payload_read "$payload" || { echo "case $label: returned non-zero"; return 1; }
    legacy=$(command_from_payload "$payload")
    [ "$(printf '%s' "$GAIA_HOOK_COMMAND" | od -An -c)" = "$(printf '%s' "$expected" | od -An -c)" ] || { echo "case $label: bytes differ"; return 1; }
    [ "$GAIA_HOOK_COMMAND" = "$expected" ] || { echo "case $label: command=[$GAIA_HOOK_COMMAND]"; return 1; }
    [ "$GAIA_HOOK_COMMAND" = "$legacy" ] || { echo "case $label: differs from the legacy read [$legacy]"; return 1; }
  done
}

@test "absent, null, false, number, object and true fields coerce to text" {
  check_field_rows \
    'null-and-false|{"tool_name":null,"session_id":false,"tool_input":{"command":null,"path":false}}||||||||' \
    'empty-object|{}||||||||' \
    'tool-input-absent|{"tool_name":"Bash","hook_event_name":"SessionStart"}|Bash|SessionStart||||||' \
    'tool-input-string|{"tool_name":"Bash","tool_input":"just a string"}|Bash|||||||' \
    'tool-input-array|{"tool_name":"Bash","tool_input":[1,2]}|Bash|||||||' \
    'number|{"session_id":12345,"tool_input":{"command":0}}|||12345|||||0' \
    'object|{"tool_input":{"command":{"a": 1, "b": [true, "x"]}}}||||||||{"a":1,"b":[true,"x"]}' \
    'true|{"tool_name":true}|true|||||||'
}

# Each row first loads a good payload, so an empty result proves the failed
# read cleared earlier state rather than never having set it.
@test "invalid JSON, an array, an empty payload, a second value or a NUL returns 1 with every variable empty" {
  local row label payload status
  for row in \
    'invalid-json|not json {' \
    'array|[{"tool_name":"Bash"}]' \
    'empty|' \
    'second-value|{"tool_name":"Bash"} {"tool_name":"Read"}' \
    'nul-in-command|{"tool_name":"Bash","tool_input":{"command":"a\u0000b"}}' \
    'nul-in-middle-field|{"tool_name":"Bash","cwd":"/a\u0000b","tool_input":{"command":"git status"}}'; do
    label=${row%%|*}; payload=${row#*|}
    gaia_hook_payload_read '{"tool_name":"Bash","tool_input":{"command":"x"}}' || { echo "case $label: good preload failed"; return 1; }
    status=0
    gaia_hook_payload_read "$payload" || status=$?
    [ "$status" -eq 1 ] || { echo "case $label: status=$status"; return 1; }
    assert_all_fields_empty || { echo "case $label: a field survived: [$(all_fields)]"; return 1; }
  done
}

@test "exactly one jq process runs per call" {
  local shim_directory="$BATS_TEST_TMPDIR/shim"
  local real_jq
  real_jq="$(command -v jq)"
  mkdir -p "$shim_directory"
  printf '#!/usr/bin/env bash\nprintf "jq\\n" >> "%s/calls.log"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  : >"$BATS_TEST_TMPDIR/calls.log"
  PATH="$shim_directory:$PATH"

  gaia_hook_payload_read '{"tool_name":"Bash","session_id":"s","cwd":"/c","hook_event_name":"PreToolUse","tool_input":{"command":"ls","file_path":"/f"}}'
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls.log" | tr -d ' ')" = "1" ]
  [ "$GAIA_HOOK_COMMAND" = "ls" ]

  gaia_hook_payload_read 'not json' && return 1
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls.log" | tr -d ' ')" = "2" ]
}

@test "a caller under set -euo pipefail is never aborted, on success or failure" {
  run bash -c '
    set -euo pipefail
    . "$1"
    gaia_hook_payload_read "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\\n\"}}"
    [ "$GAIA_HOOK_COMMAND" = "ls" ]
    for bad in "not json" "[1]" "" "{\"tool_input\":{\"command\":\"a\\u0000b\"}}"; do
      if gaia_hook_payload_read "$bad"; then echo "unexpected success: $bad"; exit 9; fi
    done
    echo survived
  ' _ "$HOOK_PAYLOAD_LIBRARY"
  [ "$status" -eq 0 ]
  [ "$output" = "survived" ]
}

@test "the function prints nothing on success or failure" {
  run gaia_hook_payload_read '{"tool_name":"Bash"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run gaia_hook_payload_read 'not json'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
