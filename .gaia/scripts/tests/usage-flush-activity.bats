#!/usr/bin/env bats
#
# usage-flush.sh: the activity facts the parse programs capture from a
# transcript range (turn openers, work chunks, waits on the maintainer, turn
# lengths, entrypoint) and the `act` field that carries them on rows the flush
# already writes.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-flush-activity.bats < /dev/null
#
# Transcripts are written line by line through helpers/usage-transcript.sh. The
# "mixed" scenario is also pinned against fixtures/usage/activity/mixed.base.jsonl
# and mixed.counts.txt, the rows the flusher wrote before `act` existed (cursor ts,
# size, offset and path normalized), so the existing row shapes stay byte-identical.

# shellcheck disable=SC2016  # jq filters and sed expressions; no shell expansion
bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FLUSH="$SCRIPTS/usage-flush.sh"
  FIXTURES_DIRECTORY="$BATS_TEST_DIRNAME/fixtures/usage/activity"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  unset GAIA_USAGE_TEST_BARRIER GAIA_USAGE_DEBUG_HOLD GAIA_TALLY_PROJECTS_ROOT
  unset GAIA_LEDGER_LOCK_FORCE_FALLBACK GAIA_LEDGER_LOCK_TIMEOUT_SECONDS
  ROOT="$TEMPORARY_DIRECTORY/repo"
  PROJECTS_DIRECTORY="$TEMPORARY_DIRECTORY/projects"
  TEL="$ROOT/.gaia/local/telemetry"
  mkdir -p "$ROOT" "$PROJECTS_DIRECTORY"
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
    commit -q --allow-empty -m init
  export UT_SESSION=s-act UT_CWD="$ROOT"
  # shellcheck source=helpers/usage-transcript.sh
  source "$BATS_TEST_DIRNAME/helpers/usage-transcript.sh"
  MAIN_PROJECTS="$PROJECTS_DIRECTORY/$(encode_project_path "$ROOT")"
  TRANSCRIPT="$MAIN_PROJECTS/s-act.jsonl"
  mkdir -p "$MAIN_PROJECTS"
}

# ---------- helpers ----------

encode_project_path() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

age() { touch -t 202001010000 "$@"; }

flush() { bash "${FLUSHER:-$FLUSH}" --projects-root "$PROJECTS_DIRECTORY" --main-root "$ROOT" "$@"; }

flush_session() { age "$TRANSCRIPT"; flush --session s-act --finished-main "$@"; }

segments() { jq -c 'select(.kind == "segment")' "$TEL/usage.jsonl"; }

# epoch_ms <iso>: milliseconds of a stamp in the form the facts use.
epoch_ms() { jq -n --arg stamp "$1" '($stamp | fromdateiso8601) * 1000'; }

# first_act: the `act` of the ledger's first segment row.
first_act() { segments | head -n 1 | jq -c '.act'; }

# normalized_rows: every ledger row with the volatile cursor fields fixed.
normalized_rows() {
  jq -c 'if .kind == "cursor" then .ts = "T" | .size = 0 | .offset = 0 | .path = "P" else . end' "$TEL/usage.jsonl"
}

# build_mixed: a main transcript (prompt, work, a wait on the maintainer, a
# turn length, a trailing away_summary), a sidecar, and a close binding that
# splits the main file's spend into two segments.
build_mixed() {
  ut_prompt "$TRANSCRIPT" 2026-10-20T10:00:00.000Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.000Z m1
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:02.000Z m2 --tool AskUserQuestion q1
  ut_tool_result "$TRANSCRIPT" 2026-10-20T10:00:30.000Z q1
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:31.000Z m3 --tool Bash b1
  ut_tool_result "$TRANSCRIPT" 2026-10-20T10:00:32.500Z b1
  ut_turn_duration "$TRANSCRIPT" 2026-10-20T10:00:33.000Z 3000
  ut_system "$TRANSCRIPT" 2026-10-20T14:00:00.000Z away_summary
  mkdir -p "$MAIN_PROJECTS/s-act/subagents"
  ut_prompt "$MAIN_PROJECTS/s-act/subagents/agent-sa1.jsonl" 2026-10-20T10:00:09.000Z
  ut_assistant "$MAIN_PROJECTS/s-act/subagents/agent-sa1.jsonl" 2026-10-20T10:00:10.000Z sa1
  printf '{"agentType":"general-purpose","description":"work"}\n' >"$MAIN_PROJECTS/s-act/subagents/agent-sa1.meta.json"
  age "$MAIN_PROJECTS/s-act/subagents/agent-sa1.jsonl"
  mkdir -p "$TEL"
  printf '%s\n' '{"schema_version":1,"kind":"binding","type":"close","session_id":"s-act","ts":"2026-10-20T10:00:30.500Z","ref":"command:gaia-wiki-1","workflow":"gaia-wiki","source":"record-command"}' >"$TEL/usage.jsonl"
}

expected_mixed_act() {
  jq -nc --argjson b "$(epoch_ms 2026-10-20T10:00:00Z)" \
    '{b: $b, e: "cli", o: [0], c: [[1, 32]], w: [[2, 28]], d: [[33, 3]]}'
}

# scratch_flusher <sed-expr>: a copy of the flusher and its libraries with one
# mutation applied to usage-parse-lib.sh; fails when the sed changed nothing.
scratch_flusher() {
  local scratch_directory="$TEMPORARY_DIRECTORY/scratch"
  mkdir -p "$scratch_directory/.gaia/scripts/spec" "$scratch_directory/.gaia/scripts/notebook"
  cp "$SCRIPTS"/usage-flush.sh "$SCRIPTS"/usage-parse-lib.sh "$SCRIPTS"/usage-lib.sh "$SCRIPTS"/main-root-lib.sh \
    "$SCRIPTS"/branch-name-lib.sh "$scratch_directory/.gaia/scripts/"
  cp "$SCRIPTS/spec/with-ledger-lock.sh" "$scratch_directory/.gaia/scripts/spec/"
  cp "$SCRIPTS"/notebook/*.sh "$scratch_directory/.gaia/scripts/notebook/"
  sed "$1" "$SCRIPTS/usage-parse-lib.sh" >"$scratch_directory/.gaia/scripts/usage-parse-lib.sh.m"
  if cmp -s "$SCRIPTS/usage-parse-lib.sh" "$scratch_directory/.gaia/scripts/usage-parse-lib.sh.m"; then
    echo "mutation did not apply to usage-parse-lib.sh" >&2
    return 1
  fi
  mv "$scratch_directory/.gaia/scripts/usage-parse-lib.sh.m" "$scratch_directory/.gaia/scripts/usage-parse-lib.sh"
  FLUSHER="$scratch_directory/.gaia/scripts/usage-flush.sh"
}

# frozen_strings_ok <file>: each guard string other suites mutate with sed
# occurs exactly once, on one line.
frozen_strings_ok() {
  local guard_string
  for guard_string in \
    '(usage_member($record.cwd; $roots) | not)' \
    '| (if $finished then null else $trailing_line end) as $hold' \
    ' or .type == "close"'; do
    [ "$(grep -cF -- "$guard_string" "$1")" -eq 1 ] || return 1
  done
}

# ---------- the facts a main transcript yields ----------

@test "a main transcript yields counts equal to the pre-facts golden, and facts with opener, chunk, wait, turn length and entrypoint" {
  build_mixed
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(jq -r -s 'group_by(.kind)[] | "\(.[0].kind) \(length)"' "$TEL/usage.jsonl")" = "$(cat "$FIXTURES_DIRECTORY/mixed.counts.txt")" ]
  [ "$(cat "$FIXTURES_DIRECTORY/mixed.counts.txt")" = "$(printf 'binding 1\ncursor 2\nsegment 3')" ]
  [ "$(first_act)" = "$(expected_mixed_act)" ]
  # the away_summary stamp (14:00) is no chunk end: the chunk stops at the last work entry
  [ "$(first_act | jq -c '.c | map(.[0] + .[1]) | max')" = "33" ]
}

@test "each opener type: a user prompt and a dequeue line with no cwd open a turn" {
  ut_prompt "$TRANSCRIPT" 2026-10-20T10:00:00.000Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.000Z m1
  ut_notification "$TRANSCRIPT" 2026-10-20T10:00:05.000Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:06.000Z m2
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(first_act | jq -c '.o')" = "[0,5]" ]
  [ "$(first_act | jq -c '.c')" = "[[1,0],[6,0]]" ]
}

@test "a queued attachment, a meta prompt and the interrupt marker open no turn" {
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.000Z m1
  ut_queued_attachment "$TRANSCRIPT" 2026-10-20T10:00:02.000Z
  ut_meta_prompt "$TRANSCRIPT" 2026-10-20T10:00:03.000Z
  ut_interrupt "$TRANSCRIPT" 2026-10-20T10:00:04.000Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:05.000Z m2
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(first_act | jq -c 'has("o")')" = "false" ]
  [ "$(first_act | jq -c '.c')" = "[[0,4]]" ]
}

@test "a line whose cwd is a string outside the roots adds no fact" {
  UT_CWD=/elsewhere/not-this-tree ut_prompt "$TRANSCRIPT" 2026-10-20T10:00:00.000Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.000Z m1
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(first_act | jq -c 'has("o")')" = "false" ]
  [ "$(first_act | jq -c '.b')" = "$(epoch_ms 2026-10-20T10:00:01Z)" ]
}

@test "a dequeue followed 10 ms later by its notification prompt with no work between is one opener" {
  ut_notification "$TRANSCRIPT" 2026-10-20T10:00:00.000Z
  ut_prompt "$TRANSCRIPT" 2026-10-20T10:00:00.010Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.000Z m1
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(first_act | jq -c '.o')" = "[0]" ]
}

@test "two user prompts with no work between are two openers" {
  ut_prompt "$TRANSCRIPT" 2026-10-20T10:00:00.000Z
  ut_prompt "$TRANSCRIPT" 2026-10-20T10:00:00.010Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.000Z m1
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(first_act | jq -c '.o')" = "[0,0]" ]
}

@test "a wait whose tool_use and result land in different flushes is q on the first and r on the second" {
  ut_prompt "$TRANSCRIPT" 2026-10-20T10:00:00.000Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.000Z m1
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:02.000Z m2 --tool AskUserQuestion wait-1
  run flush_session
  [ "$status" -eq 0 ]
  ut_tool_result "$TRANSCRIPT" 2026-10-20T10:05:00.000Z wait-1
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:05:01.000Z m3
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(segments | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(segments | sed -n 1p | jq -c '.act.q')" = '[["wait-1",2]]' ]
  [ "$(segments | sed -n 2p | jq -c '.act.r')" = '[["wait-1",0]]' ]
  [ "$(segments | sed -n 1p | jq -c '.act | has("r")')" = "false" ]
  [ "$(segments | sed -n 2p | jq -c '.act | has("q")')" = "false" ]
}

# ---------- placement ----------

@test "a range with a turn length and no usage entry writes no segment and rides on its cursor row" {
  ut_prompt "$TRANSCRIPT" 2026-10-20T10:00:00.000Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.000Z m1
  run flush_session
  [ "$status" -eq 0 ]
  local ledger_lines_before
  ledger_lines_before="$(wc -l <"$TEL/usage.jsonl" | tr -d ' ')"
  ut_turn_duration "$TRANSCRIPT" 2026-10-20T10:00:02.000Z 1500
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(segments | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(wc -l <"$TEL/usage.jsonl" | tr -d ' ')" -eq "$((ledger_lines_before + 1))" ]
  tail -n 1 "$TEL/usage.jsonl" | grep -qF '{"schema_version":1,"kind":"cursor","act":{' || return 1
  [ "$(tail -n 1 "$TEL/usage.jsonl" | jq -c '.act.d')" = "[[0,2]]" ]
  local size
  size="$(wc -c <"$TRANSCRIPT" | tr -d ' ')"
  [ "$(jq --arg path "$TRANSCRIPT" '.files[$path].offset' "$TEL/usage-cursors.json")" -eq "$size" ]
  run flush_session
  [ "$(segments | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(wc -l <"$TEL/usage.jsonl" | tr -d ' ')" -eq "$((ledger_lines_before + 1))" ]
}

@test "rows are the pre-facts rows with act appended: sidecar and later segments end in act 0, and cursors are unchanged" {
  build_mixed
  run flush_session
  [ "$status" -eq 0 ]
  local sidecar_segments later_segments
  sidecar_segments="$(segments | jq -c 'select(.agent_id == "sa1")')"
  [ "$(printf '%s\n' "$sidecar_segments" | wc -l | tr -d ' ')" -eq 1 ]
  printf '%s\n' "$sidecar_segments" | grep -q ',"act":0}$' || return 1
  later_segments="$(segments | jq -c 'select(.agent_id == null)' | tail -n +2)"
  [ "$(printf '%s\n' "$later_segments" | wc -l | tr -d ' ')" -eq 1 ]
  printf '%s\n' "$later_segments" | grep -q ',"act":0}$' || return 1
  segments | jq -c 'select(.agent_id == null)' | head -n 1 | grep -q ',"act":{' || return 1
  [ "$(normalized_rows | jq -c 'if .kind == "segment" then del(.act) else . end')" = "$(cat "$FIXTURES_DIRECTORY/mixed.base.jsonl")" ]
}

@test "holdback: an unfinished flush commits no fact at or past the held line, and the next finished flush commits them" {
  ut_prompt "$TRANSCRIPT" 2026-10-20T10:00:00.000Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.000Z m1
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:02.000Z m2 --tool Bash held-1
  ut_tool_result "$TRANSCRIPT" 2026-10-20T10:00:03.000Z held-1
  age "$TRANSCRIPT"
  run flush --session s-act
  [ "$status" -eq 0 ]
  [ "$(first_act)" = "$(jq -nc --argjson b "$(epoch_ms 2026-10-20T10:00:00Z)" '{b: $b, e: "cli", o: [0], c: [[1, 0]]}')" ]
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(segments | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(segments | sed -n 2p | jq -c '.act | {c, o: has("o"), r: has("r")}')" = '{"c":[[0,1]],"o":false,"r":false}' ]
}

@test "a relocated copy of a finished transcript read from offset 0 adds no segment and carries its facts on the cursor row" {
  ut_prompt "$TRANSCRIPT" 2026-10-20T10:00:00.000Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.000Z m1
  run flush_session
  [ "$status" -eq 0 ]
  local relocated_directory="$MAIN_PROJECTS--claude-worktrees-rel"
  mkdir -p "$relocated_directory"
  cp "$TRANSCRIPT" "$relocated_directory/s-act.jsonl"
  age "$relocated_directory/s-act.jsonl"
  run flush --session s-act --finished-main
  [ "$status" -eq 0 ]
  [ "$(segments | wc -l | tr -d ' ')" -eq 1 ]
  tail -n 1 "$TEL/usage.jsonl" | grep -qF '{"schema_version":1,"kind":"cursor","act":{' || return 1
  [ "$(tail -n 1 "$TEL/usage.jsonl" | jq -c '.act.o')" = "[0]" ]
  [ "$(tail -n 1 "$TEL/usage.jsonl" | jq -r '.path')" = "$relocated_directory/s-act.jsonl" ]
}

# ---------- timestamps ----------

@test "fact times equal usage_epoch: b in milliseconds, offsets in rounded whole seconds, for Z, fraction and +00:00 stamps, and an unparseable stamp yields no fact" {
  ut_prompt "$TRANSCRIPT" 2026-10-20T10:00:00.123Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01Z m1
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.5+00:00 m2
  ut_tool_result "$TRANSCRIPT" not-a-time orphan-1
  run flush_session
  [ "$status" -eq 0 ]
  local expected
  expected="$(bash -c '
    source "$1/usage-lib.sh" && source "$1/usage-resolve-lib.sh" || exit 9
    jq -nc "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'"'"'
      ["2026-10-20T10:00:00.123Z", "2026-10-20T10:00:01Z", "2026-10-20T10:00:01.5+00:00"]
      | map((usage_epoch * 1000 + 0.5) | floor)'"'"'' _ "$SCRIPTS")"
  [ "$(first_act | jq -c '[.b, .o[0], .c[0][0], .c[0][1]]')" = \
    "$(printf '%s' "$expected" | jq -c '.[0] as $b | def s: ((. - $b) / 1000 | round); [$b, (.[0] | s), (.[1] | s), ((.[2] | s) - (.[1] | s))]')" ]
  [ "$(first_act | jq -c 'has("r")')" = "false" ]
}

# ---------- guards must be able to fail ----------

# bats test_tags=whole-tree
@test "guard: without the cwd-less allowance a dequeue line opens no turn" {
  scratch_flusher 's/($record.cwd | type) != "string" or //'
  ut_notification "$TRANSCRIPT" 2026-10-20T10:00:00.000Z
  ut_assistant "$TRANSCRIPT" 2026-10-20T10:00:01.000Z m1
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(first_act | jq -c 'has("c")')" = "true" ]
  [ "$(first_act | jq -c '.o')" != "[0]" ]
}

# bats test_tags=whole-tree
@test "guard: with system entries counted as work the away_summary stamp lands in a chunk" {
  scratch_flusher 's/\$record.type == "assistant" or (\$tool_results/$record.type == "assistant" or $record.type == "system" or ($tool_results/'
  build_mixed
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(first_act | jq -c 'has("c")')" = "true" ]
  [ "$(first_act | jq -c '[.c[][]] | max')" != "32500" ]
}

@test "frozen strings: each guard string other suites mutate occurs exactly once in the parse library" {
  frozen_strings_ok "$SCRIPTS/usage-parse-lib.sh"
}

# bats test_tags=whole-tree
@test "guard: a parse library with a guard string duplicated fails the frozen-strings check" {
  sed '/ or \.type == "close"/p' "$SCRIPTS/usage-parse-lib.sh" >"$TEMPORARY_DIRECTORY/duplicated.sh"
  [ "$(grep -cF -- ' or .type == "close"' "$TEMPORARY_DIRECTORY/duplicated.sh")" -eq 2 ]
  run frozen_strings_ok "$TEMPORARY_DIRECTORY/duplicated.sh"
  [ "$status" -ne 0 ]
}
