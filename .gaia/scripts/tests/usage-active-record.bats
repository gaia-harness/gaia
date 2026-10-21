#!/usr/bin/env bats
#
# Active time on the Cost line `usage.sh record` prints when it closes a run,
# and in its --json form. Each ledger comes from transcripts written through
# helpers/usage-transcript.sh and the real usage-flush.sh, with the main
# checkout, telemetry directory, projects root and rate table pinned under
# $BATS_TEST_TMPDIR, and the close instant pinned with GAIA_USAGE_TEST_NOW.
# Only what no flush writes is appended by hand: spend recorded before
# activity facts existed. The rate table prices input and output at $1 per
# million, so a row's dollars equal its millions of tokens.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-active-record.bats < /dev/null

# Expected lines carry literal dollar signs and jq programs are single-quoted.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  TEL="$MAIN/.gaia/local/telemetry"
  PROJECTS="$TEMPORARY_DIRECTORY/projects"
  RATES="$TEMPORARY_DIRECTORY/rates.json"
  mkdir -p "$MAIN/.claude" "$TEL"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  # Registered capture hooks are what makes a readout print its figures.
  printf '%s\n' '{"hooks": {' \
    '  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],' \
    '  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]' \
    '}}' >"$MAIN/.claude/settings.json"
  printf '%s\n' '{"cache_multipliers": {"read": 0.1, "write_5m": 1.25, "write_1h": 2.0},' \
    ' "models": {"claude-opus-5-5": [{"input": 1, "output": 1}]}}' >"$RATES"
  ENCODED_MAIN="$(printf '%s' "$MAIN" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$PROJECTS/$ENCODED_MAIN"
  unset GAIA_TALLY_PROJECTS_ROOT GAIA_USAGE_TEST_BARRIER GAIA_USAGE_DEBUG_HOLD
  unset GAIA_USAGE_MEMO_TRACE_FILE GAIA_USAGE_MEMO_SEAM GAIA_USAGE_TEST_NOW GAIA_LEDGER_LOCK_FORCE_FALLBACK
  unset GAIA_LEDGER_LOCK_TIMEOUT_SECONDS GAIA_USAGE_BOX_FLUSH_CAP_SECONDS GAIA_USAGE_RENDER_CAP_SECONDS GAIA_USAGE_MERGE_CAP_SECONDS
  export UT_CWD="$MAIN" UT_SESSION=s-main UT_BRANCH=main UT_ENTRYPOINT=cli
  export CLAUDE_CODE_SESSION_ID=s-main
  # shellcheck source=helpers/usage-transcript.sh
  source "$BATS_TEST_DIRNAME/helpers/usage-transcript.sh"
  USAGE_SCRIPT="$SCRIPTS/usage.sh"
  REF=spec:SPEC-900
}

# ---------- transcripts ----------

DAY=2026-10-01

# at <hh:mm:ss[.fff]>: the UTC stamp of that time on the fixture day.
at() { printf '%sT%sZ' "$DAY" "$1"; }

main_file() { printf '%s/%s/%s.jsonl' "$PROJECTS" "$ENCODED_MAIN" "${1:-$UT_SESSION}"; }
sidecar_file() { printf '%s/%s/%s/subagents/agent-%s.jsonl' "$PROJECTS" "$ENCODED_MAIN" "$UT_SESSION" "$1"; }

# Lines of the current session's main transcript. Every assistant message
# spends 0.1M input tokens unless told otherwise.
prompt() { ut_prompt "$(main_file)" "$(at "$1")"; }
work() { ut_assistant "$(main_file)" "$(at "$1")" "m-$UT_SESSION-$1" --tokens "${2:-100000}" 0; }
ask() { ut_assistant "$(main_file)" "$(at "$1")" "m-$UT_SESSION-$1" --tool AskUserQuestion "$2" --tokens 100000 0; }
answer() { ut_tool_result "$(main_file)" "$(at "$1")" "$2"; }
turn_length() { ut_turn_duration "$(main_file)" "$(at "$1")" "$2"; }

# skill <hh:mm:ss> <workflow> [tokens]: the assistant Skill call that starts a
# workflow run; the flusher writes its start binding.
skill() {
  _ut_append "$(main_file)" '{type: "assistant", uuid: ("u-k-" + $session + $at), timestamp: $at,
      message: {id: ("k-" + $session + $at), model: "claude-opus-5-5", role: "assistant",
        usage: {input_tokens: $tokens, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0},
        content: [{type: "tool_use", id: ("t-k-" + $at), name: "Skill", input: {skill: $workflow}}]}} + $common' \
    --arg at "$(at "$1")" --arg session "$UT_SESSION" --arg workflow "$2" --argjson tokens "${3:-100000}"
}

# sidecar_work <agent> <hh:mm:ss> [tokens]: one sidecar message.
sidecar_work() {
  local file
  file="$(sidecar_file "$1")"
  mkdir -p "${file%/*}"
  [ -f "${file%.jsonl}.meta.json" ] || printf '{"agentType":"explore","description":"work"}\n' >"${file%.jsonl}.meta.json"
  ut_assistant "$file" "$(at "$2")" "x-$1-$2" --tokens "${3:-100000}" 0
}

# flush [session]: the real flusher over the session, every file finished.
flush() {
  bash "$SCRIPTS/usage-flush.sh" --session "${1:-$UT_SESSION}" --finished-main --all-sidecars-finished \
    --main-root "$MAIN" --telemetry-dir "$TEL" --projects-root "$PROJECTS"
}

# old_segment <session> <first> <last> <tokens>: spend recorded before activity
# facts existed, in the shape the flusher wrote then.
old_segment() {
  printf '{"schema_version":1,"kind":"segment","key":"session:%s","session_id":"%s","inherit":false,"first_ts":"%s","last_ts":"%s","messages":1,"by_model":{"claude-opus-5-5":{"fresh_input":%s,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":0}},"agent_type":"main"}\n' \
    "$1" "$1" "$(at "$2")" "$(at "$3")" "$4" >>"$TEL/usage.jsonl"
}

# ---------- readouts ----------

usage() { bash "$USAGE_SCRIPT" "$@" --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"; }

# usage_from <scripts directory> <args...>: a command run from another copy of the scripts.
usage_from() {
  local scripts_directory="$1"
  shift
  bash "$scripts_directory/usage.sh" "$@" --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"
}

# record_at <hh:mm:ss> <args...>: usage.sh record with the close instant pinned.
record_at() {
  local close="$1"
  shift
  GAIA_USAGE_TEST_NOW="$(at "$close")" usage record "$@"
}

# cost_tail: the part of the printed Cost line after its tokens and dollars.
cost_tail() { sed -n 's/^Cost: [0-9.]*M tokens, \$[0-9.]*, //p' <<<"$output"; }

# ---------- scratch copies, for the guard-red cases ----------

# scratch_scripts <directory>: a copy of the scripts a record loads, mutable
# without touching the checkout. No node_modules or other real directory is linked.
scratch_scripts() {
  local scratch="$1" file
  mkdir -p "$scratch/spec" "$scratch/notebook"
  # gaia-lint-ignore whole-tree-mark-guard: every test that reaches this helper
  # carries the per-test whole-tree mark, because it copies the scripts directory.
  for file in "$SCRIPTS"/usage*.sh "$SCRIPTS"/token-*.sh "$SCRIPTS"/token-rates.json "$SCRIPTS"/branch-name-lib.sh \
    "$SCRIPTS"/main-root-lib.sh "$SCRIPTS"/context-checkpoint-lib.sh; do
    [ -f "$file" ] && cp "$file" "$scratch/"
  done
  cp "$SCRIPTS/spec/with-ledger-lock.sh" "$scratch/spec/"
  cp "$SCRIPTS"/notebook/*.sh "$scratch/notebook/"
}

# mutate <file> <text> <replacement>: replaces the one occurrence of a literal
# text; fails when the text is absent, so a stale mutation cannot pass as red.
mutate() {
  local content
  content="$(cat "$1")"
  [ "$(grep -cF -- "$2" "$1")" -eq 1 ] || { printf 'mutation target not found once in %s: %s\n' "$1" "$2" >&2; return 1; }
  printf '%s\n' "${content/"$2"/"$3"}" >"$1"
  if grep -qF -- "$2" "$1"; then printf 'mutation did not apply to %s\n' "$1" >&2; return 1; fi
}

# ---------- scenarios ----------

# Turn 1 runs 10:00:00 to 10:05:00 with a 300 s turn length; two sub-agents it
# launched each run 10:00:30 to 10:04:30. Turn 2 opens at 11:00:00 and works
# until 11:01:00, before its own turn length exists.
build_overlapping_subagents() {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:05:00
  turn_length 10:05:00 300000
  sidecar_work a 10:00:30
  sidecar_work a 10:04:30
  sidecar_work b 10:00:30
  sidecar_work b 10:04:30
  prompt 11:00:00
  work 11:01:00
}

# The same run with a second session continuing it: the first session works
# 10:00:00 to 10:10:00, hands off, and the second works 10:05:00 to 10:15:00,
# so the two overlap for five minutes.
build_joined_overlap() {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:10:00
  UT_SESSION=s-joined
  prompt 10:05:00
  work 10:15:00
  UT_SESSION=s-main
  run_join s-main s-joined 10:10:30
}

# Two turns of the joining session, 10:03:00 to 10:04:00 and 10:05:00 to
# 10:15:00, after the first session's 10:00:00 to 10:02:00. The joining session
# also holds flushed spend from before the run, so the join starts it at the
# join instant, 10:05:00, and its 10:03:00 turn lies between the run's start
# and that.
build_late_join() {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:02:00
  UT_SESSION=s-joined
  prompt 09:00:00
  work 09:01:00
  flush s-joined
  prompt 10:03:00
  work 10:03:00
  work 10:04:00
  flush s-joined
  UT_SESSION=s-main
  run_join s-main s-joined 10:05:00
  UT_SESSION=s-joined
  prompt 10:05:00
  work 10:15:00
  UT_SESSION=s-main
}

# run_join <origin session> <joining session> <join instant>: the printed join
# line, run in the joining session at the pinned instant.
run_join() {
  local line prefix="bash .gaia/scripts/usage.sh "
  line="$(CLAUDE_CODE_SESSION_ID="$1" GAIA_USAGE_TEST_NOW="$(at "$3")" usage handoff)"
  [[ "$line" == "$prefix"* ]] || return 1
  # shellcheck disable=SC2086  # the printed line is word-split into arguments on purpose
  CLAUDE_CODE_SESSION_ID="$2" GAIA_USAGE_TEST_NOW="$(at "$3")" usage ${line#"$prefix"}
}

# ---------- the Cost line and its JSON ----------

@test "sub-agents overlapping a turn count once, and the open final turn counts to its latest work" {
  build_overlapping_subagents
  run record_at 11:01:00 "$REF" --workflow gaia-spec
  [ "$status" -eq 0 ]
  [ "$(cost_tail)" = '1h1m0s (6m0s active)' ]
}

@test "record --json carries active_seconds and active_lower_bound beside elapsed_seconds" {
  build_overlapping_subagents
  run record_at 11:01:00 "$REF" --workflow gaia-spec --json
  [ "$status" -eq 0 ]
  jq -e '.elapsed_seconds == 3660 and .active_seconds == 360 and .active_lower_bound == false' <<<"${lines[$((${#lines[@]} - 1))]}" >/dev/null
}

@test "an open final turn counts from its opener to its latest work entry, with no Note" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:02:00
  turn_length 10:02:00 120000
  prompt 11:00:00
  work 11:01:00
  run record_at 11:01:00 "$REF" --workflow gaia-spec
  [ "$status" -eq 0 ]
  [ "$(cost_tail)" = '1h1m0s (3m0s active)' ]
  grep -q '^Note:' <<<"$output" && return 1
  true
}

@test "a question wait inside a single turn is not active time" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:02:00
  ask 10:03:00 toolu-question
  answer 10:30:00 toolu-question
  work 10:32:00
  run record_at 10:32:00 "$REF" --workflow gaia-spec
  [ "$status" -eq 0 ]
  [ "$(cost_tail)" = '32m0s (5m0s active)' ]
  grep -q '^Note:' <<<"$output" && return 1
  true
}

@test "a background sub-agent running past its turn's end adds its minutes to the union" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:05:00
  turn_length 10:05:00 300000
  sidecar_work a 10:01:00
  sidecar_work a 10:05:00
  sidecar_work b 10:03:00
  sidecar_work b 10:09:00
  prompt 10:30:00
  work 10:30:00
  run record_at 10:30:00 "$REF" --workflow gaia-spec
  [ "$status" -eq 0 ]
  [ "$(cost_tail)" = '30m0s (9m0s active)' ]
}

@test "a background sub-agent still running past the close is clipped away, and the box shows the same figure afterward" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:02:00
  turn_length 10:02:00 120000
  prompt 10:30:00
  work 10:30:00
  sidecar_work a 10:30:00
  sidecar_work a 10:30:30
  work 10:31:00
  run record_at 10:31:00 "$REF" --workflow gaia-spec
  [ "$status" -eq 0 ]
  [ "$(cost_tail)" = '31m0s (3m0s active)' ]
  sidecar_work a 10:40:00
  flush
  run usage initiative "$REF" --box
  [ "$status" -eq 0 ]
  grep -qF '31m0s (3m0s active)' <<<"$output"
}

# ---------- members ----------

@test "two member sessions whose windows overlap report their union, not their sum" {
  build_joined_overlap
  run env CLAUDE_CODE_SESSION_ID=s-joined GAIA_USAGE_TEST_NOW="$(at 10:20:00)" bash "$USAGE_SCRIPT" record "$REF" --workflow gaia-spec \
    --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  [ "$(cost_tail)" = '20m0s (15m0s active)' ]
}

@test "a member's windows before its own start are excluded" {
  build_late_join
  run env CLAUDE_CODE_SESSION_ID=s-joined GAIA_USAGE_TEST_NOW="$(at 10:20:00)" bash "$USAGE_SCRIPT" record "$REF" --workflow gaia-spec \
    --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  [ "$(cost_tail)" = '20m0s (12m0s active)' ]
}

# ---------- spend recorded before facts existed ----------

@test "a member holding a fact-less segment prints a minimum and the Note after it" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:05:00
  flush
  old_segment s-main 10:06:00 10:07:00 100000
  run record_at 10:10:00 "$REF" --workflow gaia-spec
  [ "$status" -eq 0 ]
  [ "$(cost_tail)" = '10m0s (5m0s+ active)' ]
  [ "${lines[$((${#lines[@]} - 1))]}" = 'Note: Some of this spend predates active-time tracking, so the active time is a minimum.' ]
}

# ---------- the figure is additive ----------

@test "the wall clock reads the same with the active suffix removed as over a ledger holding no activity facts" {
  build_overlapping_subagents
  flush
  local stripped="$TEMPORARY_DIRECTORY/stripped"
  mkdir -p "$stripped"
  cp "$TEL/usage-cursors.json" "$stripped/"
  grep -vF '{"schema_version":1,"kind":"cursor","act":' "$TEL/usage.jsonl" | jq -c 'del(.act)' >"$stripped/usage.jsonl"
  run record_at 11:01:00 "$REF" --workflow gaia-spec
  [ "$status" -eq 0 ]
  local with_facts
  with_facts="$(grep '^Cost:' <<<"$output" | sed 's/ ([0-9hms]*+\{0,1\} active)$//')"
  [ -n "$with_facts" ]
  [ "$(grep -c ' active)' <<<"$output")" -eq 1 ]
  run record_at 11:01:00 "$REF" --workflow gaia-spec --telemetry-dir "$stripped"
  [ "$status" -eq 0 ]
  grep -q ' active)' <<<"$output" && return 1
  [ "$(grep '^Cost:' <<<"$output")" = "$with_facts" ]
}

# ---------- the guards can fail ----------

# bats test_tags=whole-tree
@test "a record that sums its members' figures instead of taking their union fails the overlap case" {
  build_joined_overlap
  local scratch="$TEMPORARY_DIRECTORY/scratch"
  scratch_scripts "$scratch"
  mutate "$scratch/usage-record-lib.sh" 'usage_active_union([.[] | (.active_pieces // [])[]]; $from; $to)' \
    '([.[] | usage_active_union(.active_pieces // []; $from; $to)] | add)'
  run env CLAUDE_CODE_SESSION_ID=s-joined GAIA_USAGE_TEST_NOW="$(at 10:20:00)" bash "$scratch/usage.sh" record "$REF" --workflow gaia-spec \
    --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  [ "$(cost_tail)" = '20m0s (20m0s active)' ]
}

# bats test_tags=whole-tree
@test "a record that clips members to the run's origin instead of their own start counts the windows before a join" {
  build_late_join
  local scratch="$TEMPORARY_DIRECTORY/scratch"
  scratch_scripts "$scratch"
  mutate "$scratch/usage-record-lib.sh" 'gaia_usage_interval_view "$member_session" "$member_start" "$interval_end"' \
    'gaia_usage_interval_view "$member_session" "$origin_start" "$interval_end"'
  run env CLAUDE_CODE_SESSION_ID=s-joined GAIA_USAGE_TEST_NOW="$(at 10:20:00)" bash "$scratch/usage.sh" record "$REF" --workflow gaia-spec \
    --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  [ -n "$(cost_tail)" ]
  [ "$(cost_tail)" != '20m0s (12m0s active)' ]
}
