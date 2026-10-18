#!/usr/bin/env bats

# Tests for the per-session effort reading the statusline writes beside the
# context reading (context-reading.sh, context-checkpoint-lib.sh). A render
# whose stdin carries a session_id and a valid effort level writes
# <session_id>.effort.json under the main checkout's cache/shared/context
# directory, whether or not it carries context_window fields; a missing or
# invalid level writes nothing and leaves the context reading and any earlier
# effort reading exactly as they were. The suite builds a temporary checkout
# and never enumerates the tracked tree.
#
# Each refusal case is a guard. Twin method: copy context-checkpoint-lib.sh or
# context-reading.sh to a scratch directory, delete the one check the case
# names (the level validation, the session id validation, or one of the read
# conditions: file exists, version, session_id match, effort validity), source
# the copy, and confirm the same case now writes or reads a value. Restore is
# discarding the scratch copy; the checkout is never edited.
#
# HOME points at an empty dir, so the left side is the shipped default.

setup() {
  STATUSLINE_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)
  SCRIPTS_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)
  SESSION_ID="0a1b2c3d-1111-4222-8333-444455556666"
  OTHER_SESSION_ID="9f8e7d6c-aaaa-4bbb-8ccc-ddddeeeeffff"

  MAIN=$(mktemp -d -t gaia-effort-main-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/scripts" "$MAIN/.gaia/local"
  cp "$STATUSLINE_SOURCE"/*.sh "$MAIN/.gaia/statusline/"
  cp "$SCRIPTS_SOURCE/main-root-lib.sh" "$SCRIPTS_SOURCE/context-checkpoint-lib.sh" "$MAIN/.gaia/scripts/"
  echo x >"$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m init
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' >"$MAIN/.gaia/local/setup-state.json"
  CONTEXT_DIRECTORY="$MAIN/.gaia/local/cache/shared/context"
  TEMPORARY_HOME=$(mktemp -d -t gaia-effort-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# payload <session_id> <effort level, may be empty>: a render with context_window fields.
payload() {
  jq -n --arg current_directory "$MAIN" --arg session_id "$1" --arg level "$2" \
    '{session_id: $session_id, workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Claude Opus"}, effort: {level: $level},
      context_window: {used_percentage: 25, context_window_size: 1000000, total_input_tokens: 1}}'
}

render() {
  PAYLOAD="$1" run env HOME="$TEMPORARY_HOME" COLUMNS=200 bash -c "printf '%s' \"\$PAYLOAD\" | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
}

effort_file() { printf '%s/%s.effort.json' "$CONTEXT_DIRECTORY" "$1"; }

# library <shell snippet>: run a snippet with the lib sourced.
library() {
  run bash -c ". '$MAIN/.gaia/scripts/context-checkpoint-lib.sh'; $1"
}

@test "a render with a level and context fields writes both readings and leaves no temporary file" {
  render "$(payload "$SESSION_ID" high)"
  [ "$status" -eq 0 ]
  jq -e '.version == 1 and .session_id == "'"$SESSION_ID"'" and .effort == "high" and (.written_at | type == "number")' "$(effort_file "$SESSION_ID")" >/dev/null
  jq -e '.version == 1 and .session_id == "'"$SESSION_ID"'" and (.used_tokens | type == "number")' "$CONTEXT_DIRECTORY/$SESSION_ID.json" >/dev/null
  if find "$CONTEXT_DIRECTORY" -name '*.tmp.*' | grep -q .; then
    echo "tmp file left behind"
    return 1
  fi
}

@test "a render with a level and no context_window writes the effort reading and no context reading" {
  render "$(payload "$SESSION_ID" medium | jq 'del(.context_window)')"
  [ "$status" -eq 0 ]
  [ "$(jq -r .effort "$(effort_file "$SESSION_ID")")" = "medium" ]
  [ ! -e "$CONTEXT_DIRECTORY/$SESSION_ID.json" ]
}

@test "red: an empty level writes the context reading as today and no effort reading" {
  render "$(payload "$SESSION_ID" "")"
  [ "$status" -eq 0 ]
  [ -f "$CONTEXT_DIRECTORY/$SESSION_ID.json" ]
  [ ! -e "$(effort_file "$SESSION_ID")" ]
}

@test "red: an unknown level writes the context reading as today and no effort reading" {
  render "$(payload "$SESSION_ID" extreme)"
  [ "$status" -eq 0 ]
  [ -f "$CONTEXT_DIRECTORY/$SESSION_ID.json" ]
  [ ! -e "$(effort_file "$SESSION_ID")" ]
}

@test "red: a render without a level leaves an earlier valid effort reading unchanged" {
  render "$(payload "$SESSION_ID" high)"
  [ "$status" -eq 0 ]
  local before
  before=$(cat "$(effort_file "$SESSION_ID")")
  render "$(payload "$SESSION_ID" "")"
  [ "$status" -eq 0 ]
  render "$(payload "$SESSION_ID" extreme)"
  [ "$status" -eq 0 ]
  [ "$(cat "$(effort_file "$SESSION_ID")")" = "$before" ]
}

@test "two sessions rendered at different levels each read back their own" {
  render "$(payload "$SESSION_ID" high)"
  [ "$status" -eq 0 ]
  render "$(payload "$OTHER_SESSION_ID" low)"
  [ "$status" -eq 0 ]
  library "gaia_context_effort_read '$MAIN' '$SESSION_ID'"
  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
  library "gaia_context_effort_read '$MAIN' '$OTHER_SESSION_ID'"
  [ "$status" -eq 0 ]
  [ "$output" = "low" ]
}

@test "red: gaia_context_effort_write refuses a non-UUID session id" {
  library "gaia_context_effort_write '$MAIN' 'not-a-uuid' high 1700000000"
  [ "$status" -eq 1 ]
  [ ! -e "$CONTEXT_DIRECTORY" ]
}

@test "red: gaia_context_effort_write refuses a path-traversal session id" {
  library "gaia_context_effort_write '$MAIN' '../../x' high 1700000000"
  [ "$status" -eq 1 ]
  [ ! -e "$CONTEXT_DIRECTORY" ]
}

@test "red: gaia_context_effort_write refuses an invalid level" {
  library "gaia_context_effort_write '$MAIN' '$SESSION_ID' extreme 1700000000"
  [ "$status" -eq 1 ]
  [ ! -e "$CONTEXT_DIRECTORY" ]
}

@test "red: gaia_context_effort_write refuses a non-integer epoch" {
  library "gaia_context_effort_write '$MAIN' '$SESSION_ID' high soon"
  [ "$status" -eq 1 ]
  [ ! -e "$CONTEXT_DIRECTORY" ]
}

# seed_effort <json>: a hand-written effort file for the read refusals.
seed_effort() {
  mkdir -p "$CONTEXT_DIRECTORY"
  printf '%s\n' "$1" >"$(effort_file "$SESSION_ID")"
}

@test "red: gaia_context_effort_read refuses a missing file" {
  library "gaia_context_effort_read '$MAIN' '$SESSION_ID'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "red: gaia_context_effort_read refuses a corrupt file" {
  seed_effort 'not json at all'
  library "gaia_context_effort_read '$MAIN' '$SESSION_ID'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "red: gaia_context_effort_read refuses a version other than 1" {
  seed_effort '{"version":2,"session_id":"'"$SESSION_ID"'","effort":"high","written_at":1700000000}'
  library "gaia_context_effort_read '$MAIN' '$SESSION_ID'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "red: gaia_context_effort_read refuses a mismatched session id" {
  seed_effort '{"version":1,"session_id":"'"$OTHER_SESSION_ID"'","effort":"high","written_at":1700000000}'
  library "gaia_context_effort_read '$MAIN' '$SESSION_ID'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "red: gaia_context_effort_read refuses an invalid effort" {
  seed_effort '{"version":1,"session_id":"'"$SESSION_ID"'","effort":"extreme","written_at":1700000000}'
  library "gaia_context_effort_read '$MAIN' '$SESSION_ID'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "gaia_context_effort_read accepts a well-formed file of any age" {
  seed_effort '{"version":1,"session_id":"'"$SESSION_ID"'","effort":"xhigh","written_at":1}'
  library "gaia_context_effort_read '$MAIN' '$SESSION_ID'"
  [ "$status" -eq 0 ]
  [ "$output" = "xhigh" ]
}
