#!/usr/bin/env bats
#
# `usage.sh record` copies the effort level the statusline last saw for the
# session a close row names onto that row, and only that level: no reading, an
# invalid reading, or a missing library leaves the row without an `effort` key
# and the record's exit status and stdout untouched. The readings come from the
# real statusline, rendered with cwd set to the temporary main checkout so they
# land where `record --main-root` reads them. Ids are UUID-shaped because the
# reading is keyed by a UUID session id.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-record-effort.bats
#
# jq programs and expected lines are single-quoted on purpose.
# shellcheck disable=SC2016

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

SESSION_S="aaaaaaaa-1111-4222-8333-000000000001"
SESSION_T="aaaaaaaa-1111-4222-8333-000000000002"

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GAIA_SOURCE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RATES="$BATS_TEST_DIRNAME/fixtures/usage/resolve/rates-a.json"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  TEMPORARY_HOME="$TEMPORARY_DIRECTORY/home"
  mkdir -p "$TEMPORARY_HOME"
  unset GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_TEST_BARRIER GAIA_USAGE_DEBUG_HOLD GAIA_LEDGER_LOCK_TIMEOUT_SECONDS
  unset GAIA_USAGE_MERGE_CAP_SECONDS GAIA_USAGE_RENDER_CAP_SECONDS GAIA_LEDGER_LOCK_FORCE_FALLBACK
  new_fixture main
  USAGE_SCRIPT="$SCRIPTS/usage.sh"
}

# ---------- helpers ----------

# new_fixture <name>: a fresh main checkout, telemetry directory and projects
# tree, with the statusline scripts a render needs copied in.
new_fixture() {
  MAIN="$TEMPORARY_DIRECTORY/$1"
  TEL="$MAIN/.gaia/local/telemetry"
  PROJECTS="$TEMPORARY_DIRECTORY/$1-projects"
  mkdir -p "$MAIN/.claude" "$TEL" "$MAIN/.gaia/statusline" "$MAIN/.gaia/scripts"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  printf '%s\n' '{"hooks": {' \
    '  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],' \
    '  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]' \
    '}}' >"$MAIN/.claude/settings.json"
  cp "$GAIA_SOURCE"/statusline/*.sh "$MAIN/.gaia/statusline/"
  cp "$SCRIPTS/main-root-lib.sh" "$SCRIPTS/context-checkpoint-lib.sh" "$MAIN/.gaia/scripts/"
  ENCODED_MAIN="$(printf '%s' "$MAIN" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$PROJECTS/$ENCODED_MAIN"
  as_session "$SESSION_S"
}

as_session() {
  SID="$1"
  export CLAUDE_CODE_SESSION_ID="$SID"
}

record() { bash "$USAGE_SCRIPT" record "$@" --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"; }
usage() { bash "$USAGE_SCRIPT" "$@" --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"; }

main_file() { printf '%s/%s/%s.jsonl' "$PROJECTS" "$ENCODED_MAIN" "$SID"; }

# stamp <hh:mm>: a UTC stamp on a fixed day well before now.
stamp() { printf '2026-10-01T%s:00Z' "$1"; }

# main_usage <id> <hh:mm> <fresh input> <output>
main_usage() {
  mkdir -p "$(dirname "$(main_file)")"
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"%s","cwd":"%s","sessionId":"%s","gitBranch":"main","message":{"id":"%s","model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":%s},"content":[{"type":"text","text":"ok"}]}}\n' \
    "$1" "$(stamp "$2")" "$MAIN" "$SID" "$1" "$3" "$4" >>"$(main_file)"
}
# main_start <id> <hh:mm> <workflow>: the transcript line a Skill call writes.
main_start() {
  mkdir -p "$(dirname "$(main_file)")"
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"%s","cwd":"%s","sessionId":"%s","gitBranch":"main","message":{"id":"%s","model":"claude-opus-5-5","role":"assistant","content":[{"type":"tool_use","id":"t-%s","name":"Skill","input":{"skill":"%s"}}]}}\n' \
    "$1" "$(stamp "$2")" "$MAIN" "$SID" "$1" "$1" "$3" >>"$(main_file)"
}

ledger() { printf '%s/usage.jsonl' "$TEL"; }
close_row() { jq -c --arg sid "$1" 'select(.kind == "binding" and .type == "close" and .session_id == $sid)' "$(ledger)"; }
# close_has_effort <session> <level>: rc 0 when that session's close row carries the level.
close_has_effort() { close_row "$1" | jq -e --arg level "$2" '.effort == $level' >/dev/null; }
last_stdout_line() { printf '%s' "${lines[$((${#lines[@]} - 1))]}"; }

# render_effort <session id> <level> [with-context]: one statusline render for
# that session, cwd at the main checkout. Without the third argument the stdin
# carries no context_window.
render_effort() {
  local json
  json="$(jq -n --arg cwd "$MAIN" --arg session_id "$1" --arg level "$2" '{session_id: $session_id, workspace: {current_dir: $cwd}, cwd: $cwd, model: {display_name: "Claude Opus"}, effort: {level: $level}}')"
  if [ "${3:-}" = with-context ]; then
    json="$(jq -c '. + {context_window: {used_percentage: 20, context_window_size: 1000000}}' <<<"$json")"
  fi
  PAYLOAD="$json" HOME="$TEMPORARY_HOME" COLUMNS=200 bash -c "printf '%s' \"\$PAYLOAD\" | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'" >/dev/null 2>&1
}

effort_file() { printf '%s/.gaia/local/cache/shared/context/%s.effort.json' "$MAIN" "$1"; }

# start_joined_run: session S starts a gaia-spec run, session T joins it, and the
# run is recorded from S. Readings are rendered by the caller beforehand.
start_joined_run() {
  as_session "$SESSION_S"
  main_start s1 10:00 gaia-spec
  main_usage m1 10:10 1000 0
  as_session "$SESSION_T"
  run usage join --workflow gaia-spec --session "$SESSION_S" --start "$(stamp 10:00)"
  [ "$status" -eq 0 ]
  main_usage j1 11:00 2000 0
  as_session "$SESSION_S"
  main_usage m2 11:30 3000 0
}

# scratch_scripts <dir>: a copy of the scripts the record path loads, mutable
# without touching the checkout. No node_modules or other real directory is linked.
scratch_scripts() {
  local scratch="$1" file
  mkdir -p "$scratch/spec"
  for file in "$SCRIPTS"/usage*.sh "$SCRIPTS"/token-*.sh "$SCRIPTS"/token-rates.json "$SCRIPTS"/branch-name-lib.sh \
    "$SCRIPTS"/main-root-lib.sh "$SCRIPTS"/context-checkpoint-lib.sh; do
    [ -f "$file" ] && cp "$file" "$scratch/"
  done
  cp "$SCRIPTS/spec/with-ledger-lock.sh" "$scratch/spec/"
  mkdir -p "$scratch/notebook"
  cp "$SCRIPTS"/notebook/*.sh "$scratch/notebook/"
}

# The Cost line's last field is elapsed time since a fixed past day, which moves
# between runs, so a twin comparison drops it.
without_elapsed() { printf '%s' "${1%, *}"; }

# ---------- cases ----------

@test "each close row carries its own session's level, never the recording session's" {
  render_effort "$SESSION_S" high with-context
  render_effort "$SESSION_T" low
  start_joined_run
  run record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.kind == "binding" and .type == "close")] | length' "$(ledger)")" -eq 2 ]
  close_has_effort "$SESSION_S" high
  close_has_effort "$SESSION_T" low
  jq -s -e '[.[] | select(.kind == "binding" and .type == "close")] | map(.effort) | sort == ["high", "low"]' "$(ledger)" >/dev/null
  jq -e '.schema_version == 1' <<<"$(close_row "$SESSION_S")" >/dev/null
}

@test "a session with no valid reading gets no effort key and the record is unchanged" {
  local plain_status plain_line
  start_joined_run
  run record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 0 ]
  plain_status="$status"
  plain_line="$(without_elapsed "$(last_stdout_line)")"
  close_row "$SESSION_S" | jq -e 'has("effort") | not' >/dev/null
  close_row "$SESSION_T" | jq -e 'has("effort") | not' >/dev/null

  new_fixture twin
  render_effort "$SESSION_S" extreme with-context
  render_effort "$SESSION_T" ""
  mkdir -p "$(dirname "$(effort_file "$SESSION_T")")"
  printf '%s\n' '{"version":1,"session_id":"'"$SESSION_T"'","effort":"extreme","written_at":1}' >"$(effort_file "$SESSION_T")"
  start_joined_run
  run record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq "$plain_status" ]
  [ "$(without_elapsed "$(last_stdout_line)")" = "$plain_line" ]
  close_row "$SESSION_S" | jq -e 'has("effort") | not' >/dev/null
  close_row "$SESSION_T" | jq -e 'has("effort") | not' >/dev/null
}

@test "a reading far older than the context freshness window is still recorded" {
  local old_file
  render_effort "$SESSION_S" medium
  old_file="$(effort_file "$SESSION_S")"
  jq -c '.written_at = 1' "$old_file" >"$old_file.edit"
  mv "$old_file.edit" "$old_file"
  as_session "$SESSION_S"
  main_start s1 10:00 gaia-spec
  main_usage m1 10:10 1000 0
  run record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 0 ]
  close_has_effort "$SESSION_S" medium
}

@test "a render with a level and no context_window is recorded" {
  render_effort "$SESSION_S" xhigh
  [ ! -e "$MAIN/.gaia/local/cache/shared/context/$SESSION_S.json" ]
  as_session "$SESSION_S"
  main_start s1 10:00 gaia-spec
  main_usage m1 10:10 1000 0
  run record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 0 ]
  close_has_effort "$SESSION_S" xhigh
}

@test "a recovery record adds effort to the close row only, never to the synthetic start row" {
  render_effort "$SESSION_S" max
  as_session "$SESSION_S"
  main_usage m1 10:10 1000 0
  run record spec:SPEC-901 --workflow gaia-spec --start "$(stamp 10:05)"
  [ "$status" -eq 0 ]
  close_has_effort "$SESSION_S" max
  jq -s -e '[.[] | select(.kind == "binding" and .type == "start")] | length == 1 and all(.[]; has("effort") | not)' "$(ledger)" >/dev/null
}

@test "guard twin: without the reader the effort assertion fails while the record still exits 0" {
  local scratch="$TEMPORARY_DIRECTORY/scratch-scripts"
  render_effort "$SESSION_S" high with-context
  render_effort "$SESSION_T" low
  start_joined_run
  scratch_scripts "$scratch"
  printf '%s\n' '# a library with no effort reader' >"$scratch/context-checkpoint-lib.sh"
  USAGE_SCRIPT="$scratch/usage.sh"
  run record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 0 ]
  [[ "$(last_stdout_line)" == "Cost: "* ]]
  [ "$(jq -s '[.[] | select(.kind == "binding" and .type == "close")] | length' "$(ledger)")" -eq 2 ]
  run close_has_effort "$SESSION_S" high
  [ "$status" -ne 0 ]
  run close_has_effort "$SESSION_T" low
  [ "$status" -ne 0 ]
}
