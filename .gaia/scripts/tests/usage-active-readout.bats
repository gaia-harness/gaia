#!/usr/bin/env bats
#
# Active time in the readouts that print a time: `usage.sh initiative <ref>
# --line` and `--box`, `usage.sh pr <N>`, their --json forms, and the interval
# view. Each ledger comes from transcripts written through
# helpers/usage-transcript.sh and the real usage-flush.sh, with the main
# checkout, telemetry directory, projects root and rate table pinned under
# $BATS_TEST_TMPDIR. Only what no flush writes is appended by hand: spend
# recorded before activity facts existed (a fact-less segment and its run's
# start binding), the close bindings `usage.sh record` writes, and the activity
# rows a backfill appends. The rate table prices input and
# output at $1 per million, so a row's dollars equal its millions of tokens.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-active-readout.bats < /dev/null

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
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GAIA_USAGE_TEST_BARRIER GAIA_USAGE_DEBUG_HOLD
  unset GAIA_USAGE_MEMO_TRACE_FILE GAIA_USAGE_MEMO_SEAM GAIA_USAGE_TEST_NOW GAIA_LEDGER_LOCK_FORCE_FALLBACK
  unset GAIA_LEDGER_LOCK_TIMEOUT_SECONDS GAIA_USAGE_BOX_FLUSH_CAP_SECONDS GAIA_USAGE_RENDER_CAP_SECONDS GAIA_USAGE_MERGE_CAP_SECONDS
  export UT_CWD="$MAIN" UT_SESSION=s-main UT_BRANCH=main UT_ENTRYPOINT=cli
  # shellcheck source=helpers/usage-transcript.sh
  source "$BATS_TEST_DIRNAME/helpers/usage-transcript.sh"
  USAGE_SCRIPT="$SCRIPTS/usage.sh"
  FLUSH_SCRIPT="$SCRIPTS/usage-flush.sh"
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
tool_call() { ut_assistant "$(main_file)" "$(at "$1")" "m-$UT_SESSION-$1" --tool Bash "$2" --tokens 100000 0; }
answer() { ut_tool_result "$(main_file)" "$(at "$1")" "$2"; }
turn_length() { ut_turn_duration "$(main_file)" "$(at "$1")" "$2"; }
system_entry() { ut_system "$(main_file)" "$(at "$1")" "$2"; }
notification() { ut_notification "$(main_file)" "$(at "$1")"; }
interrupt() { ut_interrupt "$(main_file)" "$(at "$1")"; }

# skill <hh:mm:ss> <workflow> [tokens]: the assistant Skill call that starts a
# workflow run; the flusher writes its start binding.
skill() {
  _ut_append "$(main_file)" '{type: "assistant", uuid: ("u-k-" + $session + $at), timestamp: $at,
      message: {id: ("k-" + $session + $at), model: "claude-opus-5-5", role: "assistant",
        usage: {input_tokens: $tokens, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0},
        content: [{type: "tool_use", id: ("t-k-" + $at), name: "Skill", input: {skill: $workflow}}]}} + $common' \
    --arg at "$(at "$1")" --arg session "$UT_SESSION" --arg workflow "$2" --argjson tokens "${3:-100000}"
}

# sidecar_work <agent> <agent_type> <hh:mm:ss> [tokens]: one sidecar message.
sidecar_work() {
  local file
  file="$(sidecar_file "$1")"
  mkdir -p "${file%/*}"
  [ -f "${file%.jsonl}.meta.json" ] || printf '{"agentType":"%s","description":"work"}\n' "$2" >"${file%.jsonl}.meta.json"
  ut_assistant "$file" "$(at "$3")" "x-$1-$3" --tokens "${4:-100000}" 0
}

# flush [session]: the real flusher over the session, every file finished.
flush() {
  bash "$FLUSH_SCRIPT" --session "${1:-$UT_SESSION}" --finished-main --all-sidecars-finished \
    --main-root "$MAIN" --telemetry-dir "$TEL" --projects-root "$PROJECTS"
}

# ---------- rows no flush writes ----------

close_run() {
  printf '{"schema_version":1,"kind":"binding","type":"close","session_id":"%s","ts":"%s","ref":"%s","workflow":"%s","source":"record-command"}\n' \
    "$1" "$(at "$2")" "$3" "$4" >>"$TEL/usage.jsonl"
}
start_run() {
  printf '{"schema_version":1,"kind":"binding","type":"start","session_id":"%s","ts":"%s","workflow":"%s","source":"transcript"}\n' \
    "$1" "$(at "$2")" "$3" >>"$TEL/usage.jsonl"
}
# old_segment <session> <key> <first> <last> <tokens>: spend recorded before
# activity facts existed, in the shape the flusher wrote then.
old_segment() {
  printf '{"schema_version":1,"kind":"segment","key":"%s","session_id":"%s","inherit":false,"first_ts":"%s","last_ts":"%s","messages":1,"by_model":{"claude-opus-5-5":{"fresh_input":%s,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":0}},"agent_type":"main"}\n' \
    "$2" "$1" "$(at "$3")" "$(at "$4")" "$5" >>"$TEL/usage.jsonl"
}

# ---------- readouts ----------

usage() { bash "$USAGE_SCRIPT" "$@" --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"; }

# usage_from <scripts directory> <args...>: a readout run from another copy of the scripts.
usage_from() {
  local scripts_directory="$1"
  shift
  bash "$scripts_directory/usage.sh" "$@" --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"
}

# ---------- scratch copies, for the guard-red cases ----------

# scratch_scripts <directory>: a copy of the scripts a readout loads, mutable
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

# legacy_scripts <directory>: a copy whose memo parse cannot compile, so every
# readout falls back to the pre-memo sequence.
legacy_scripts() {
  scratch_scripts "$1"
  mutate "$1/usage-memo-lib.sh" 'def usage_present($usage_records; $links):' 'def usage_present(($usage_records; $links):'
}

# without_active <file>: the readout with every active suffix, the active Note
# and the blank line before it (when it is the only Note) removed, box borders
# and padding collapsed, since a shorter figure narrows the box.
without_active() {
  awk '
    { lines[NR] = $0 }
    END {
      note = "Note: Some of this spend predates active-time tracking, so the active time is a minimum."
      for (i = 1; i <= NR; i++) {
        line = lines[i]
        if (line == note) continue
        if (line == "" && lines[i + 1] == note && lines[i + 2] !~ /^Note: /) continue
        gsub(/ \([0-9hms]+\+? active\)/, "", line)
        if (line ~ /^\+-+\+$/) line = "+-+"
        sub(/ +\|$/, " |", line)
        print line
      }
    }' "$1"
}

# stripped_telemetry <directory>: a telemetry directory holding the ledger with
# every `act` key and every fact-carrying cursor row removed.
stripped_telemetry() {
  mkdir -p "$1"
  if [ -f "$TEL/links.jsonl" ]; then cp "$TEL/links.jsonl" "$1/"; fi
  if [ -f "$TEL/usage-cursors.json" ]; then cp "$TEL/usage-cursors.json" "$1/"; fi
  grep -vF '{"schema_version":1,"kind":"cursor","act":' "$TEL/usage.jsonl" | jq -c 'del(.act)' >"$1/usage.jsonl"
}

# ---------- scenarios ----------

# Two closed turns two hours apart, each a minute of work with a 60 s turn length.
build_idle_gap() {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:01:00
  turn_length 10:01:00 60000
  prompt 12:00:00
  work 12:00:00
  work 12:01:00
  turn_length 12:01:00 60000
  flush
  close_run s-main 12:01:00 "$REF" gaia-spec
}

# Spec and Plan runs in one session, and Other work: a segment recorded before
# facts existed and a second session whose one turn overlaps the Plan's first.
build_three_rows() {
  prompt 10:00:00
  skill 10:00:00 gaia-spec 250000
  work 10:05:00 250000
  prompt 10:25:00
  work 10:25:00 250000
  work 10:30:00 250000
  flush
  close_run s-main 10:30:00 "$REF" gaia-spec
  prompt 10:32:00
  skill 10:32:00 gaia-plan 500000
  work 10:40:00 500000
  prompt 10:58:00
  work 10:58:00 500000
  work 11:00:00 500000
  flush
  close_run s-main 11:00:00 "$REF" gaia-plan
  usage link research:active-topic "$REF" >/dev/null
  usage declare research:active-topic --session s-old --at "$(at 08:59:00)" >/dev/null
  old_segment s-old session:s-old 09:00:00 09:10:00 1500000
  usage declare research:active-topic --session s-other --at "$(at 10:34:00)" >/dev/null
  UT_SESSION=s-other
  prompt 10:35:00
  work 10:35:00 750000
  work 10:45:00 750000
  flush s-other
  UT_SESSION=s-main
}

# A run recorded before facts existed (09:00 to 09:10) and one closed turn after
# it, 10:00:00 to 10:12:04, with a 724 s turn length.
build_mixed() {
  start_run s-old 08:59:00 gaia-spec
  old_segment s-old session:s-old 09:00:00 09:10:00 100000
  close_run s-old 09:11:00 "$REF" gaia-spec
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:05:00
  work 10:12:04
  turn_length 10:12:04 724000
  flush
  close_run s-main 10:12:05 "$REF" gaia-spec
}

# activity_backfill <session> <from> <to>: the backfill row covering spend
# recorded before facts existed with one turn of work over the same span.
activity_backfill() {
  local base_milliseconds seconds
  base_milliseconds="$(jq -n --arg stamp "$(at "$2")" '($stamp | fromdateiso8601) * 1000')"
  seconds="$(jq -n --arg from "$(at "$2")" --arg to "$(at "$3")" '($to | fromdateiso8601) - ($from | fromdateiso8601)')"
  printf '{"schema_version":1,"kind":"activity","session_id":"%s","cover":["%s","%s"],"act":{"b":%s,"e":"cli","o":[0],"c":[[0,%s]]}}\n' \
    "$1" "$(at "$2")" "$(at "$3")" "$base_milliseconds" "$seconds" >>"$TEL/usage.jsonl"
}

AUDITORS=code-audit-frontend,code-audit-maintainer-shell

# One session on a feature branch: main turns 10:00 to 10:10 (600 s) and 11:00
# to 11:05 (300 s), and two auditors launched in the second turn, 11:00 to
# 11:04 and 11:01 to 11:05. PR 101 merged at noon.
build_per_pr() {
  UT_BRANCH=feat/active-pr
  prompt 10:00:00
  work 10:00:00
  work 10:10:00
  turn_length 10:10:00 600000
  prompt 11:00:00
  work 11:00:00
  work 11:05:00
  turn_length 11:05:00 300000
  sidecar_work a1 code-audit-frontend 11:00:00
  sidecar_work a1 code-audit-frontend 11:04:00
  sidecar_work a2 code-audit-maintainer-shell 11:01:00
  sidecar_work a2 code-audit-maintainer-shell 11:05:00
  flush
  UT_BRANCH=main
  usage link --merge 101 --branch feat/active-pr --merged-at "$(at 12:00:00)" >/dev/null
}

# build_binding_cap [after-work] [after-length]: work 10:00 to 10:10 with no
# recorded wait and a 240 s turn length, then a minute at noon with a 60 s one.
# The hooks run between the lines (a flush, or nothing).
build_binding_cap() {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:05:00
  work 10:10:00
  "${1:-true}"
  turn_length 10:10:00 240000
  "${2:-true}"
  prompt 12:00:00
  work 12:00:00
  work 12:01:00
  turn_length 12:01:00 60000
  flush
  close_run s-main 12:01:00 "$REF" gaia-spec
}

# The first turn's work in one flush and its turn length alone in the next,
# where only the cursor row can carry it.
build_cursor_only_facts() { build_binding_cap flush flush; }

# A per-PR ledger with a branch segment recorded before facts existed and a
# covered session: the main thread and one auditor.
build_per_pr_mixed() {
  old_segment s-old branch:feat/mixed-pr 09:00:00 09:10:00 100000
  UT_BRANCH=feat/mixed-pr
  prompt 10:00:00
  work 10:00:00
  work 10:05:00
  turn_length 10:05:00 300000
  sidecar_work a1 code-audit-frontend 10:01:00
  sidecar_work a1 code-audit-frontend 10:03:00
  flush
  UT_BRANCH=main
  usage link --merge 102 --branch feat/mixed-pr --merged-at "$(at 12:00:00)" >/dev/null
}

# Spend recorded before facts existed only: Spec, Plan and branch work under one root.
build_fact_less() {
  start_run s2 09:00:00 gaia-spec
  old_segment s2 session:s2 09:10:00 09:20:00 1000000
  close_run s2 09:30:00 "$REF" gaia-spec
  start_run s3 10:00:00 gaia-plan
  old_segment s3 session:s3 10:10:00 10:20:00 2000000
  close_run s3 10:40:00 "$REF" gaia-plan
  old_segment s4 branch:feat/build-x 11:00:00 11:45:00 3000000
  usage link branch:feat/build-x "$REF" >/dev/null
}

# ---------- the line ----------

@test "an idle gap between two closed turns is left out: the line shows two minutes active beside the two-hour wall clock" {
  build_idle_gap
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.4M tokens, $0.40, 2h1m0s (2m0s active)' ]
}

@test "a seven-minute tool call that writes nothing while it runs counts in full" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  tool_call 10:01:00 t-bash
  answer 10:08:00 t-bash
  work 10:09:00
  turn_length 10:09:00 540000
  prompt 12:00:00
  work 12:00:00
  work 12:01:00
  turn_length 12:01:00 60000
  flush
  close_run s-main 12:01:00 "$REF" gaia-spec
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.5M tokens, $0.50, 2h1m0s (10m0s active)' ]
}

@test "spend recorded before facts existed beside covered spend prints the active figure as a minimum with the Note, and JSON says so" {
  build_mixed
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.4M tokens, $0.40, 1h12m4s (12m4s+ active)
Note: Some of this spend predates active-time tracking, so the active time is a minimum.' ]
  run usage initiative "$REF" --line --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.elapsed_seconds, .active_seconds, .active_lower_bound]' <<<"$output")" = '[4324,724,true]' ]
}

@test "a question wait is left out even when a flush runs inside it" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  ask 10:02:00 t-ask
  flush
  answer 10:08:00 t-ask
  work 10:10:00
  turn_length 10:10:00 240000
  prompt 12:00:00
  work 12:00:00
  work 12:01:00
  turn_length 12:01:00 60000
  flush
  close_run s-main 12:01:00 "$REF" gaia-spec
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.5M tokens, $0.50, 2h1m0s (5m0s active)' ]
}

@test "a notification turn counts from its own opener even when its turn length reaches back to the human prompt" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:01:00
  turn_length 10:01:00 60000
  notification 10:04:00
  prompt 10:04:00.005
  work 10:05:00
  work 10:06:00
  turn_length 10:06:00 360000
  flush
  close_run s-main 10:06:00 "$REF" gaia-spec
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.4M tokens, $0.40, 6m0s (3m0s active)' ]
}

@test "an interrupted turn with no turn length counts to its last work entry and is not marked a minimum" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:02:30
  interrupt 10:02:31
  prompt 11:00:00
  work 11:00:00
  work 11:01:00
  turn_length 11:01:00 60000
  flush
  close_run s-main 11:01:00 "$REF" gaia-spec
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.4M tokens, $0.40, 1h1m0s (3m30s active)' ]
}

# two_prompt_session <session> <ref>: two five-minute stretches of work ten
# minutes apart, no turn lengths, closed under its own root.
two_prompt_session() {
  UT_SESSION="$1"
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:05:00
  prompt 10:15:00
  work 10:15:00
  work 10:20:00
  flush
  close_run "$1" 10:20:00 "$2" gaia-spec
  UT_SESSION=s-main
}

@test "a headless session counts its whole work span; its interactive twin counts its turns" {
  UT_ENTRYPOINT=sdk-cli two_prompt_session s-headless spec:SPEC-901
  UT_ENTRYPOINT=cli two_prompt_session s-interactive spec:SPEC-902
  run usage initiative spec:SPEC-901 --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.4M tokens, $0.40, 20m0s (20m0s active)' ]
  run usage initiative spec:SPEC-902 --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.4M tokens, $0.40, 20m0s (10m0s active)' ]
}

@test "trailing stop-hook and away summaries are not work and do not extend a turn" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:04:00
  system_entry 10:04:00 stop_hook_summary
  system_entry 10:07:00 away_summary
  prompt 11:00:00
  work 11:00:00
  work 11:01:00
  flush
  close_run s-main 11:01:00 "$REF" gaia-spec
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.4M tokens, $0.40, 1h1m0s (5m0s active)' ]
}

@test "a mid-turn question wait is subtracted and an overlapping sub-agent counts once" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  ask 10:04:00 t-ask
  answer 10:10:00 t-ask
  work 10:10:00
  turn_length 10:10:00 240000
  sidecar_work a1 general-purpose 10:00:00
  sidecar_work a1 general-purpose 10:04:00
  flush
  close_run s-main 10:10:00 "$REF" gaia-spec
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.5M tokens, $0.50, 10m0s (4m0s active)' ]
}

@test "with no turn lengths anywhere each turn counts its own work less its question wait" {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:03:00
  system_entry 10:03:00 stop_hook_summary
  prompt 10:30:00
  ask 10:31:00 t-ask
  answer 10:40:00 t-ask
  work 10:43:00
  system_entry 10:43:00 stop_hook_summary
  prompt 11:00:00
  work 11:00:00
  work 11:02:00
  system_entry 11:02:00 stop_hook_summary
  flush
  close_run s-main 11:02:00 "$REF" gaia-spec
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.6M tokens, $0.60, 1h2m0s (9m0s active)' ]
}

@test "a turn length shorter than the turn's work caps it through the line readout" {
  build_binding_cap
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.5M tokens, $0.50, 2h1m0s (5m0s active)' ]
}

@test "a turn length that arrives alone in a later flush rides the cursor row and still caps the turn, cold and warm" {
  build_cursor_only_facts
  grep -qF '{"schema_version":1,"kind":"cursor","act":{' "$TEL/usage.jsonl" || return 1
  local trace="$TEMPORARY_DIRECTORY/trace.log"
  GAIA_USAGE_MEMO_TRACE_FILE="$trace" run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.5M tokens, $0.50, 2h1m0s (5m0s active)' ]
  GAIA_USAGE_MEMO_TRACE_FILE="$trace" run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.5M tokens, $0.50, 2h1m0s (5m0s active)' ]
  grep -qx 'path=cold reason=missing' "$trace"
  grep -qx 'path=warm' "$trace"
}

@test "the stretch from a prompt to the first spend falls outside the line's span" {
  prompt 10:00:00
  skill 10:01:00 gaia-spec
  work 10:03:00
  turn_length 10:03:00 180000
  flush
  close_run s-main 10:03:00 "$REF" gaia-spec
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.2M tokens, $0.20, 2m0s (2m0s active)' ]
}

# ---------- the box ----------

# The box of the three-row ledger: workflow rows clip to their runs, Other work
# to its own spend, and the Total is the union over the whole root, so the
# Plan's overlap with the second session counts once.
THREE_ROW_BOX='SPEC-900 Cost

+---------------------------------------------------------+
|       Spec: 1.0M tokens, $1.00, 30m0s (10m0s active)    |
|       Plan: 2.0M tokens, $2.00, 28m0s (10m0s active)    |
| Other work: 3.0M tokens, $3.00, 1h45m0s (10m0s+ active) |
+---------------------------------------------------------+
|      Total: 6.0M tokens, $6.00, 2h0m0s (25m0s+ active)  |
+---------------------------------------------------------+

Note: Some of this spend predates active-time tracking, so the active time is a minimum.'

# Today's readouts over the fact-less ledger, as the scripts before active time
# printed them.
FACT_LESS_LINE='Cost: 6.0M tokens, $6.00, 2h35m0s'
FACT_LESS_BOX='SPEC-900 Cost

+--------------------------------------+
|    Spec: 1.0M tokens, $1.00, 30m0s   |
|    Plan: 2.0M tokens, $2.00, 40m0s   |
| Execute: 3.0M tokens, $3.00, 45m0s   |
+--------------------------------------+
|   Total: 6.0M tokens, $6.00, 2h35m0s |
+--------------------------------------+'

PER_PR_BOX='PR #101 Cost

+----------------------------------------------------+
| Execute: 0.4M tokens, $0.40, 1h5m0s (15m0s active) |
|   Audit: 0.4M tokens, $0.40, 5m0s (5m0s active)    |
+----------------------------------------------------+
|   Total: 0.8M tokens, $0.80, 1h5m0s (15m0s active) |
+----------------------------------------------------+
  ! lower bound: branch spend may predate coverage start'

# active_pairs: each JSON object carrying elapsed_seconds, as its
# [active_seconds, active_lower_bound] pair, distinct.
active_pairs() { jq -c '[.. | objects | select(has("elapsed_seconds")) | [.active_seconds, .active_lower_bound]] | unique'; }

@test "spend recorded before facts existed reads exactly as before: no active figure, no active Note, and null figures in JSON" {
  build_fact_less
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = "$FACT_LESS_LINE" ]
  run usage initiative "$REF" --box
  [ "$status" -eq 0 ]
  [ "$output" = "$FACT_LESS_BOX" ]
  run usage initiative "$REF" --line --json
  [ "$status" -eq 0 ]
  [ "$(active_pairs <<<"$output")" = '[[null,false]]' ]
  run usage initiative "$REF" --box --json
  [ "$status" -eq 0 ]
  [ "$(jq '[.. | objects | select(has("elapsed_seconds"))] | length' <<<"$output")" -eq 4 ]
  [ "$(active_pairs <<<"$output")" = '[[null,false]]' ]
}

@test "the three-row box prints the pinned readout: per-row figures, a Total that is the union, and the active Note" {
  build_three_rows
  run usage initiative "$REF" --box
  [ "$status" -eq 0 ]
  [ "$output" = "$THREE_ROW_BOX" ]
}

@test "box, line and per-PR JSON carry active seconds and the lower-bound flag beside every elapsed figure" {
  build_three_rows
  run usage initiative "$REF" --box --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.rows[] | [.label, .active_seconds, .active_lower_bound]]' <<<"$output")" = '[["Spec",600,false],["Plan",600,false],["Other work",600,true]]' ]
  [ "$(jq -c '.total | [.active_seconds, .active_lower_bound]' <<<"$output")" = '[1500,true]' ]
  run usage initiative "$REF" --line --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.elapsed_seconds, .active_seconds, .active_lower_bound]' <<<"$output")" = '[7200,1500,true]' ]
}

@test "the per-PR JSON carries the active figure at its top level, in audit and in the rest" {
  build_per_pr
  run usage pr 101 --auditors "$AUDITORS" --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.active_seconds, .active_lower_bound, .audit.active_seconds, .audit.active_lower_bound, .audit.rest.active_seconds, .audit.rest.active_lower_bound]' <<<"$output")" = '[900,false,300,false,900,false]' ]
}

@test "a one-row box over covered spend prints the plain Cost line with the active figure" {
  build_idle_gap
  run usage initiative "$REF" --box
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.4M tokens, $0.40, 2h1m0s (2m0s active)' ]
}

@test "a one-row box over mixed spend prints the minimum form and the active Note after it" {
  build_mixed
  run usage initiative "$REF" --box
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.4M tokens, $0.40, 1h13m5s (12m4s+ active)
Note: Some of this spend predates active-time tracking, so the active time is a minimum.' ]
}

# build_straddle <close> <plan start> <spec last work> <plan last work>: one
# turn that a Spec close and the Plan's Skill call split, with no turn length.
build_straddle() {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work "$3"
  close_run s-main "$1" "$REF" gaia-spec
  skill "$2" gaia-plan
  work "$4"
  flush
  close_run s-main "$4" "$REF" gaia-plan
}

# split_rows: the Spec and Plan active seconds, then the line's, space-separated.
split_rows() {
  printf '%s %s\n' "$(usage initiative "$REF" --box --json | jq -r '[.rows[].active_seconds] | join(" ")')" \
    "$(usage initiative "$REF" --line --json | jq -r '.active_seconds')"
}

@test "a turn split by a Spec close and the Plan start gives each row its own side, and the two sum to the turn" {
  build_straddle 10:05:00 10:05:00 10:04:00 10:10:00
  [ "$(split_rows)" = '300 300 600' ]
}

@test "a close that falls between two entries half a second apart splits the turn where the flusher split its segments" {
  build_straddle 10:05:00.250 10:05:00.500 10:05:00.000 10:10:00.500
  [ "$(jq -sc '[.[] | select(.kind == "segment") | [.first_ts, .last_ts]]' "$TEL/usage.jsonl")" = \
    '[["2026-10-01T10:00:00Z","2026-10-01T10:05:00.000Z"],["2026-10-01T10:05:00.500Z","2026-10-01T10:10:00.500Z"]]' ]
  [ "$(split_rows)" = '300 300 600' ]
}

# ---------- flush boundaries ----------

# split_flush_session <pieces|whole>: the idle-gap session plus a sub-agent
# launched in its second turn, 12:00:10 to 12:00:50. In pieces, a flush at
# 12:00:30 commits the second turn's prompt and both transcripts so far.
split_flush_session() {
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:01:00
  turn_length 10:01:00 60000
  prompt 12:00:00
  work 12:00:00
  sidecar_work a1 general-purpose 12:00:10
  sidecar_work a1 general-purpose 12:00:30
  if [ "$1" = pieces ]; then flush; fi
  sidecar_work a1 general-purpose 12:00:50
  work 12:01:00
  turn_length 12:01:00 60000
  flush
  # After the last entry: a run holds a segment that starts before its close,
  # and the second piece's main segment starts at 12:01:00.
  close_run s-main 12:01:30 "$REF" gaia-spec
}

@test "a single flush of the complete transcripts and their sub-agent counts the second turn once" {
  split_flush_session whole
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.7M tokens, $0.70, 2h1m0s (2m0s active)' ]
}

@test "a two-piece flush, then a relocated re-read of both transcripts from offset zero, leave the figure as one flush gives it" {
  split_flush_session pieces
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.7M tokens, $0.70, 2h1m0s (2m0s active)' ]
  local relocated="$PROJECTS/$ENCODED_MAIN--claude-worktrees-relocated" sidecar
  sidecar="$(sidecar_file a1)"
  mkdir -p "$relocated/s-main/subagents"
  cp "$(main_file)" "$relocated/s-main.jsonl"
  cp "$sidecar" "${sidecar%.jsonl}.meta.json" "$relocated/s-main/subagents/"
  touch -t 202001010000 "$relocated/s-main.jsonl" "$relocated/s-main/subagents/agent-a1.jsonl"
  flush
  jq -e --arg path "$relocated/s-main.jsonl" 'select(.kind == "cursor" and .path == $path) | has("act")' "$TEL/usage.jsonl" >/dev/null
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.7M tokens, $0.70, 2h1m0s (2m0s active)' ]
}

# ---------- backfill and the per-PR block ----------

@test "an activity row covering the spend recorded before facts existed makes the line's figure exact, with no Note" {
  build_mixed
  activity_backfill s-old 09:00:00 09:10:00
  run usage initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.4M tokens, $0.40, 1h12m4s (22m4s active)' ]
}

@test "the per-PR box prints the active figure on Execute, Audit and Total, with overlapping auditors counted once" {
  build_per_pr
  run usage pr 101 --auditors "$AUDITORS"
  [ "$status" -eq 0 ]
  [ "$output" = "$PER_PR_BOX" ]
}

@test "the per-PR block announces a minimum through its marker only, never the active Note" {
  build_per_pr_mixed
  run usage pr 102 --auditors "$AUDITORS"
  [ "$status" -eq 0 ]
  grep -qx '  ! lower bound: some spend predates active-time tracking' <<<"$output"
  grep -qx '|   Total: 0.5M tokens, $0.50, 1h5m0s (5m0s+ active) |' <<<"$output"
  grep -q '^Note: Some of this spend predates' <<<"$output" && return 1
  true
}

@test "an activity row covering the per-PR spend recorded before facts existed removes the minimum marker" {
  build_per_pr_mixed
  activity_backfill s-old 09:00:00 09:10:00
  run usage pr 102 --auditors "$AUDITORS"
  [ "$status" -eq 0 ]
  grep -qx '|   Total: 0.5M tokens, $0.50, 1h5m0s (15m0s active) |' <<<"$output"
  grep -qF 'some spend predates active-time tracking' <<<"$output" && return 1
  true
}

# ---------- wall clock is unchanged ----------

# same_wall_clock <readout args...>: the readout over the ledger, its active
# figures removed, equals the readout over the same ledger stripped of facts.
same_wall_clock() {
  local stripped="$TEMPORARY_DIRECTORY/stripped"
  [ -d "$stripped" ] || stripped_telemetry "$stripped"
  usage "$@" >"$TEMPORARY_DIRECTORY/with-facts.txt"
  usage "$@" --telemetry-dir "$stripped" >"$TEMPORARY_DIRECTORY/without-facts.txt"
  grep -q ' active)' "$TEMPORARY_DIRECTORY/with-facts.txt"
  grep -q ' active)' "$TEMPORARY_DIRECTORY/without-facts.txt" && return 1
  diff <(without_active "$TEMPORARY_DIRECTORY/with-facts.txt") <(without_active "$TEMPORARY_DIRECTORY/without-facts.txt")
}

@test "with its active figures removed, every readout equals the same readout over the ledger stripped of facts" {
  build_idle_gap
  same_wall_clock initiative "$REF" --line
  same_wall_clock initiative "$REF" --box
}

@test "the three-row and mixed ledgers keep their wall clock, tokens, dollars and Notes once the active figures are removed" {
  build_three_rows
  same_wall_clock initiative "$REF" --line
  same_wall_clock initiative "$REF" --box
  rm -rf "$TEL" "$TEMPORARY_DIRECTORY/stripped" "${PROJECTS:?}/$ENCODED_MAIN"
  mkdir -p "$TEL" "$PROJECTS/$ENCODED_MAIN"
  build_mixed
  same_wall_clock initiative "$REF" --line
  same_wall_clock initiative "$REF" --box
}

@test "the per-PR box keeps its wall clock and markers once the active figures are removed" {
  build_per_pr
  same_wall_clock pr 101 --auditors "$AUDITORS"
}

# ---------- memo parity ----------

# parity <expected> <readout args...>: the readout prints the expected text
# cold, warm, and through the pre-memo fallback.
parity() {
  local expected="$1" trace="$TEMPORARY_DIRECTORY/parity-trace.log" legacy="$TEMPORARY_DIRECTORY/legacy"
  shift
  rm -f "$trace"
  [ "$(GAIA_USAGE_MEMO_TRACE_FILE="$trace" usage "$@")" = "$expected" ]
  grep -qx 'path=cold reason=missing' "$trace"
  [ "$(GAIA_USAGE_MEMO_TRACE_FILE="$trace" usage "$@")" = "$expected" ]
  grep -qx 'path=warm' "$trace"
  [ -d "$legacy" ] || legacy_scripts "$legacy"
  [ "$(GAIA_USAGE_MEMO_TRACE_FILE="$trace" usage_from "$legacy" "$@")" = "$expected" ]
  grep -qx 'fallback=legacy' "$trace"
}

# bats test_tags=whole-tree
@test "the idle-gap line reads the same cold, warm and through the pre-memo fallback" {
  build_idle_gap
  parity 'Cost: 0.4M tokens, $0.40, 2h1m0s (2m0s active)' initiative "$REF" --line
}

# bats test_tags=whole-tree
@test "the three-row box reads the same cold, warm and through the pre-memo fallback" {
  build_three_rows
  parity "$THREE_ROW_BOX" initiative "$REF" --box
}

# bats test_tags=whole-tree
@test "the per-PR box reads the same cold, warm and through the pre-memo fallback" {
  build_per_pr
  parity "$PER_PR_BOX" pr 101 --auditors "$AUDITORS"
}

# bats test_tags=whole-tree
@test "a turn length carried only on a cursor row caps the line cold, warm and through the pre-memo fallback" {
  build_cursor_only_facts
  parity 'Cost: 0.5M tokens, $0.50, 2h1m0s (5m0s active)' initiative "$REF" --line
}

# ---------- the guards can fail ----------

# bats test_tags=whole-tree
@test "a memo prefilter that drops every cursor row loses the turn length a cursor row carries" {
  build_cursor_only_facts
  local scratch="$TEMPORARY_DIRECTORY/scratch"
  scratch_scripts "$scratch"
  mutate "$scratch/usage-memo-lib.sh" "grep -v '^{\"schema_version\":1,\"kind\":\"cursor\",\"session_id\":'" "grep -v '^{\"schema_version\":1,\"kind\":\"cursor\",'"
  run usage_from "$scratch" initiative "$REF" --line
  [ "$status" -eq 0 ]
  [ "$output" = 'Cost: 0.5M tokens, $0.50, 2h1m0s (11m0s active)' ]
}

# bats test_tags=whole-tree
@test "a box Total that sums its rows instead of taking their union fails the pinned box" {
  build_three_rows
  local scratch="$TEMPORARY_DIRECTORY/scratch"
  scratch_scripts "$scratch"
  mutate "$scratch/usage-render-lib.sh" '+ usage_elapsed_active($active_index; $root.segments))};' \
    '+ usage_elapsed_active($active_index; $root.segments))} | .total.active_seconds = ([.rows[].active_seconds // 0] | add);'
  run usage_from "$scratch" initiative "$REF" --box
  [ "$status" -eq 0 ]
  [ "$output" != "$THREE_ROW_BOX" ]
  grep -qF 'Total: 6.0M tokens, $6.00, 2h0m0s (30m0s+ active)' <<<"$output"
}

# bats test_tags=whole-tree
@test "a Cost line that takes any fourth argument as seconds appends a suffix to a legacy four-argument call" {
  local scratch="$TEMPORARY_DIRECTORY/scratch" call
  scratch_scripts "$scratch"
  call='. "$1/usage-active-lib.sh" && . "$1/usage-render-lib.sh" || exit 9; gaia_usage_cost_line 49999 0.004 45 "legacy terms \$0.00"'
  run bash -c "$call" _ "$SCRIPTS"
  [ "$output" = 'Cost: 0.0M tokens, $0.00, 45s' ]
  mutate "$scratch/usage-render-lib.sh" '[[ ${1-} =~ ^[0-9]+$ ]] || return 0' '[ -n "${1-}" ] || return 0'
  run bash -c "$call" _ "$scratch"
  [[ "$output" == 'Cost: 0.0M tokens, $0.00, 45s ('*' active)' ]]
}

# bats test_tags=whole-tree
@test "a box that always prints the active Note fails the per-PR marker-only rule" {
  build_per_pr_mixed
  local scratch="$TEMPORARY_DIRECTORY/scratch"
  scratch_scripts "$scratch"
  mutate "$scratch/usage-render-lib.sh" '[ "$announce" = note ] || minimum_shown=false' ':'
  run usage_from "$scratch" pr 102 --auditors "$AUDITORS"
  [ "$status" -eq 0 ]
  grep -q '^Note: Some of this spend predates' <<<"$output"
}

# record_at <scripts directory> <session> <with|without>: a gaia-spec run of
# the session recorded with the test clock set, inside or outside a bats run;
# prints the close row's ts.
record_at() {
  local scripts_directory="$1" session="$2"
  UT_SESSION="$session"
  prompt 10:00:00
  skill 10:00:00 gaia-spec
  work 10:01:00
  UT_SESSION=s-main
  if [ "$3" = without ]; then
    env -u BATS_TEST_TMPDIR GAIA_USAGE_TEST_NOW=2000-01-01T00:00:00Z CLAUDE_CODE_SESSION_ID="$session" \
      bash "$scripts_directory/usage.sh" record "$REF" --workflow gaia-spec --quiet --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"
  else
    GAIA_USAGE_TEST_NOW=2000-01-01T00:00:00Z CLAUDE_CODE_SESSION_ID="$session" \
      bash "$scripts_directory/usage.sh" record "$REF" --workflow gaia-spec --quiet --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"
  fi
  jq -r --arg session "$session" 'select(.kind == "binding" and .type == "close" and .session_id == $session) | .ts' "$TEL/usage.jsonl"
}

# bats test_tags=whole-tree
@test "the test clock applies only inside a bats run, and a seam without that condition would leak out of one" {
  DAY=1999-12-31
  run record_at "$SCRIPTS" s-outside without
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" != 2000* ]]
  run record_at "$SCRIPTS" s-inside with
  [ "$status" -eq 0 ]
  [ "$output" = 2000-01-01T00:00:00Z ]
  local scratch="$TEMPORARY_DIRECTORY/scratch"
  scratch_scripts "$scratch"
  mutate "$scratch/usage.sh" '[ -n "${GAIA_USAGE_TEST_NOW:-}" ] && [ -n "${BATS_TEST_TMPDIR:-}" ]' '[ -n "${GAIA_USAGE_TEST_NOW:-}" ]'
  run record_at "$scratch" s-leak without
  [ "$status" -eq 0 ]
  [ "$output" = 2000-01-01T00:00:00Z ]
}
