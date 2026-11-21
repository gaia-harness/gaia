#!/usr/bin/env bats
#
# Suite for .claude/hooks/context-override-session-start.sh: the session-start
# warning for a context checkpoint override that is off, clamped or invalid.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/context-override-session-start.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK="$REPO_ROOT/.claude/hooks/context-override-session-start.sh"
  MAIN="$BATS_TEST_TMPDIR/main"
  mkdir -p "$MAIN/.gaia/local/protected"
  git -C "$MAIN" init -q
  MAIN="$(cd "$MAIN" && pwd -P)"
  OVERRIDE_FILE="$MAIN/.gaia/local/protected/checkpoint-override.json"
}

# start [<override json>]: run the hook on a startup payload for the fixture,
# writing the override first when one is given.
start() {
  [ $# -eq 0 ] || printf '%s\n' "$1" >"$OVERRIDE_FILE"
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "{\"session_id\":\"s\",\"source\":\"startup\",\"cwd\":\"$MAIN\"}" "$HOOK"
}

# message: the systemMessage the hook printed, after checking that the
# additionalContext carries the same text.
message() {
  local system_message
  system_message=$(jq -r '.systemMessage' <<<"$output") || return 1
  [ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" = "$system_message" ] || return 1
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = SessionStart ] || return 1
  printf '%s' "$system_message"
}

@test "silent with no file and with an in-range value" {
  start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  start '{"version":1,"context_checkpoint":{"ask_tokens":300000}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "each off, out-of-range or invalid override names the file and the fix, and a clamp names the value read and the value used" {
  local text
  echo "case: below the minimum"
  start '{"version":1,"context_checkpoint":{"ask_tokens":100000}}'
  [ "$status" -eq 0 ]
  text=$(message) || return 1
  [[ $text == "WARNING: "*"$OVERRIDE_FILE sets ask_tokens to 100000, below the 200,000 minimum, so 200,000 is used. Set ask_tokens from 200000 to 400000." ]] || return 1

  echo "case: above the maximum"
  start '{"version":1,"context_checkpoint":{"ask_tokens":500000}}'
  text=$(message) || return 1
  [[ $text == "WARNING: "*"$OVERRIDE_FILE sets ask_tokens to 500000, above the 400,000 limit, so 400,000 is used. To go higher, set ask_tokens to 0"* ]] || return 1

  echo "case: off"
  start '{"version":1,"context_checkpoint":{"ask_tokens":0}}'
  text=$(message) || return 1
  [[ $text == *"is OFF: $OVERRIDE_FILE sets ask_tokens to 0"*"Not recommended"*"300,000 default"* ]] || return 1

  echo "case: invalid, whose text carries quotes the JSON must escape"
  start '{"version":1,"context_checkpoint":{"ask_tokens":"abc"}}'
  text=$(message) || return 1
  [[ $text == "WARNING: "*"is invalid: $OVERRIDE_FILE is not {\"version\":1,"*"so the 300,000 default is used. Fix or delete the file." ]] || return 1
}

@test "a missing library or no payload exits 0 silently" {
  run bash -c 'printf "" | bash "$1"' _ "$HOOK"
  [ "$status" -eq 0 ]
  local copy="$BATS_TEST_TMPDIR/copy/.claude/hooks"
  mkdir -p "$copy"
  cp "$HOOK" "$copy/"
  printf '%s\n' '{"version":1,"context_checkpoint":{"ask_tokens":0}}' >"$OVERRIDE_FILE"
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "{\"cwd\":\"$MAIN\"}" "$copy/context-override-session-start.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
