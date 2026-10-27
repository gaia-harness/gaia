#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-dispatch-cost.sh beyond a dispatch that ran:
# members recorded as not dispatched, the adopter gate, the project-folder
# scope of the transcript lookup, the never-block contract, parity with the
# committed toolkit, `report` delegation and the release registration.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$REPO_ROOT/.gaia/tests/helpers/audit-roster.sh"
  SCRIPT="$REPO_ROOT/.gaia/scripts/audit-dispatch-cost.sh"
  REPORT_SCRIPT="$REPO_ROOT/.gaia/scripts/audit-dispatch-cost-report.sh"
  FIXTURE="$REPO_ROOT/.gaia/tests/audit-cost/fixtures/dispatch-cost"
  RATES_FILE="$REPO_ROOT/.gaia/scripts/token-rates.json"
  [ -f "$SCRIPT" ]
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  MEMBER="code-audit-frontend"
  MEMBER_ID=a0000000000000001
  SESSION_ID=11111111-2222-3333-4444-555555555555
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/.gaia" "$ROOT/.claude/rules/maintainers"
  printf '1.6.1\n' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" init --quiet --initial-branch=main
  git -C "$ROOT" config user.email "test@example.com"
  git -C "$ROOT" config user.name "Test"
  git -C "$ROOT" config commit.gpgsign false
  echo "# readme" > "$ROOT/README.md"
  seed_audit_roster "$ROOT"
  git -C "$ROOT" add .gaia/audit-ci.yml .gaia/VERSION README.md
  git -C "$ROOT" commit --quiet -m "init"
  . "$REPO_ROOT/.gaia/tests/helpers/catchup-fixture.sh"
  git -C "$ROOT" remote add origin "$BATS_TEST_TMPDIR/placeholder-origin.git"
  catchup_add_origin "$ROOT" main --feature feat/dispatch-cost
  MAINTAINER_RULE="$ROOT/.claude/rules/maintainers/harness-triage-threshold.md"
  printf '# maintainer rule\n' > "$MAINTAINER_RULE"
  TELEMETRY_DIRECTORY="$ROOT/.gaia/local/telemetry"
  LOG="$TELEMETRY_DIRECTORY/audit-light-routing.jsonl"

  . "$REPO_ROOT/.gaia/scripts/main-root-lib.sh"
  . "$REPO_ROOT/.gaia/scripts/usage-lib.sh"
  ENCODED="$(gaia_usage_encode_path "$(gaia_resolve_main_root "$ROOT")")"
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  export GAIA_TALLY_PROJECTS_ROOT="$PROJECTS"
  export GAIA_DISPATCH_COST_FINISH_WAIT_SECONDS=1
  install_session "$ENCODED"
}

teardown() {
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# install_session <project-folder>: the fixture laid out as Claude Code does.
install_session() {
  mkdir -p "$PROJECTS/$1/$SESSION_ID"
  cp "$FIXTURE/session.jsonl" "$PROJECTS/$1/$SESSION_ID.jsonl"
  cp -R "$FIXTURE/session/subagents" "$PROJECTS/$1/$SESSION_ID/subagents"
}

record() {
  STATUS=0
  OUT="$BATS_TEST_TMPDIR/record.out"
  ERR="$BATS_TEST_TMPDIR/record.err"
  bash "$SCRIPT" record --root "$ROOT" "$@" >"$OUT" 2>"$ERR" || STATUS=$?
}

line_count() {
  if [ -f "$LOG" ]; then wc -l <"$LOG" | tr -d ' '; else echo 0; fi
}

field() {
  jq -r "$2" <<<"$1"
}

# expect_nothing_recorded: exit 0, empty stdout, no new line, at most one
# stderr line.
expect_nothing_recorded() {
  [ "$STATUS" -eq 0 ]
  [ ! -s "$OUT" ]
  [ "$(line_count)" = 0 ]
  [ "$(wc -l <"$ERR" | tr -d ' ')" -le 1 ]
}

within() {
  awk -v a="$1" -v b="$2" -v tolerance="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= tolerance + 0.000000001) }'
}

@test "not dispatched: one event per member with the figure fields null" {
  local first second
  record --kind member --state not_dispatched --reason already_cleared --member code-audit-frontend --member code-audit-maintainer-shell
  [ "$STATUS" -eq 0 ]
  [ ! -s "$OUT" ]
  [ "$(line_count)" = 2 ]
  first="$(sed -n 1p "$LOG")"
  second="$(sed -n 2p "$LOG")"
  [ "$(field "$first" '.member')" = code-audit-frontend ]
  [ "$(field "$second" '.member')" = code-audit-maintainer-shell ]
  for event in "$first" "$second"; do
    [ "$(field "$event" '.state')" = not_dispatched ]
    [ "$(field "$event" '.reason')" = already_cleared ]
    [ "$(field "$event" '.kind')" = member ]
    [ "$(field "$event" '.schema')" = 1 ]
    [ "$(field "$event" '[.branch, .digest, .tree] | map(. != null and . != "") | all')" = true ]
    [ "$(field "$event" '[.agent_id, .agent_type, .incomplete, .finish, .claude_code_version, .own, .children_state, .children, .children_dollars] | map(. == null) | all')" = true ]
  done
}

@test "not dispatched: a bad reason, a missing reason or an agent id appends nothing" {
  record --kind member --state not_dispatched --reason zero_scope --member "$MEMBER"
  expect_nothing_recorded
  record --kind member --state not_dispatched --reason '' --member "$MEMBER"
  expect_nothing_recorded
  record --kind member --state not_dispatched --member "$MEMBER"
  expect_nothing_recorded
  record --kind member --state not_dispatched --reason already_cleared --member "$MEMBER" --agent-id x
  expect_nothing_recorded
  record --kind light_reviewer --state not_dispatched --reason already_cleared --member "$MEMBER"
  expect_nothing_recorded
  record --kind member --member a --member b --agent-id "$MEMBER_ID"
  expect_nothing_recorded
}

@test "adopter gate: without the maintainer marker nothing is appended or created" {
  rm -f "$MAINTAINER_RULE"
  record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID"
  [ "$STATUS" -eq 0 ]
  [ ! -s "$OUT" ]
  [ ! -s "$ERR" ]
  [ ! -e "$TELEMETRY_DIRECTORY" ]
  record --kind member --state not_dispatched --reason already_cleared --member "$MEMBER"
  [ "$STATUS" -eq 0 ]
  [ ! -e "$TELEMETRY_DIRECTORY" ]
}

@test "lookup scope: a transcript only under an unrelated project is never read" {
  local other="$PROJECTS/-some-other-project/$SESSION_ID/subagents"
  rm -rf "$PROJECTS"
  mkdir -p "$other"
  cp "$FIXTURE/session/subagents/agent-$MEMBER_ID.jsonl" "$other/"
  cp "$FIXTURE/session/subagents/agent-$MEMBER_ID.meta.json" "$other/"
  chmod 000 "$other/agent-$MEMBER_ID.jsonl"
  record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID"
  [ "$STATUS" -eq 0 ]
  [ "$(line_count)" = 1 ]
  [ "$(field "$(cat "$LOG")" '.state')" = transcript_missing ]
  grep -qF -- "some-other-project" "$ERR" && return 1
  true
}

# bats test_tags=whole-tree
@test "lookup scope: a copy of the recorder with a widened glob does find it" {
  local other="$PROJECTS/-some-other-project/$SESSION_ID/subagents" widened
  rm -rf "$PROJECTS"
  mkdir -p "$other"
  cp "$FIXTURE/session/subagents/agent-$MEMBER_ID.jsonl" "$other/"
  cp "$FIXTURE/session/subagents/agent-$MEMBER_ID.meta.json" "$other/"

  # The copy resolves its libraries and the digest helper's hook library relative
  # to itself, so both trees travel with it into the test's own directory.
  mkdir -p "$BATS_TEST_TMPDIR/copy/.gaia" "$BATS_TEST_TMPDIR/copy/.claude/hooks"
  cp -R "$REPO_ROOT/.gaia/scripts" "$BATS_TEST_TMPDIR/copy/.gaia/scripts"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$BATS_TEST_TMPDIR/copy/.claude/hooks/lib"
  widened="$BATS_TEST_TMPDIR/copy/.gaia/scripts/audit-dispatch-cost.sh"
  # shellcheck disable=SC2016 # the sed program must reach sed with its `$` literal
  sed 's#"\$projects_root/\$encoded"/\*/subagents#"$projects_root"/*/*/subagents#' "$SCRIPT" >"$widened"
  cmp -s "$SCRIPT" "$widened" && return 1
  bash "$widened" record --root "$ROOT" --kind member --member "$MEMBER" --agent-id "$MEMBER_ID" >/dev/null 2>&1 || true
  [ "$(field "$(cat "$LOG")" '.state')" = ok ]

  rm -f "$LOG"
  record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID"
  [ "$(field "$(cat "$LOG")" '.state')" = transcript_missing ]
}

@test "never block: jq off the PATH" {
  local empty_bin="$BATS_TEST_TMPDIR/empty-bin"
  mkdir -p "$empty_bin"
  STATUS=0
  PATH="$empty_bin" /bin/bash "$SCRIPT" record --root "$ROOT" --kind member --member "$MEMBER" --agent-id "$MEMBER_ID" \
    >"$BATS_TEST_TMPDIR/record.out" 2>"$BATS_TEST_TMPDIR/record.err" || STATUS=$?
  OUT="$BATS_TEST_TMPDIR/record.out"
  ERR="$BATS_TEST_TMPDIR/record.err"
  expect_nothing_recorded
}

@test "never block: malformed arguments append nothing" {
  record --kind member --member "$MEMBER" --agent-id ../x
  expect_nothing_recorded
  record --kind member --member "$MEMBER" --agent-id 'a*'
  expect_nothing_recorded
  record --kind member --member a/b --agent-id "$MEMBER_ID"
  expect_nothing_recorded
  record --kind member --agent-id "$MEMBER_ID"
  expect_nothing_recorded
  record --kind member --member "$MEMBER" --agent-id ''
  expect_nothing_recorded
  record --kind bogus --member "$MEMBER" --agent-id "$MEMBER_ID"
  expect_nothing_recorded
  record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID" --bogus
  expect_nothing_recorded
  STATUS=0
  OUT="$BATS_TEST_TMPDIR/record.out"
  ERR="$BATS_TEST_TMPDIR/record.err"
  bash "$SCRIPT" record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID" >"$OUT" 2>"$ERR" || STATUS=$?
  expect_nothing_recorded
}

@test "never block: an unwritable telemetry directory is swallowed" {
  mkdir -p "$TELEMETRY_DIRECTORY"
  chmod 555 "$TELEMETRY_DIRECTORY"
  record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID"
  chmod 755 "$TELEMETRY_DIRECTORY"
  expect_nothing_recorded
}

@test "never block: a rates override that cannot load records nothing and names the rates" {
  mkdir -p "$TELEMETRY_DIRECTORY"
  printf 'not json {\n' >"$TELEMETRY_DIRECTORY/token-rates.override.json"
  record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID"
  expect_nothing_recorded
  [ "$(wc -l <"$ERR" | tr -d ' ')" = 1 ]
  grep -qi -- "rates" "$ERR"
}

# bats test_tags=whole-tree
@test "parity: the event's figures match the toolkit field by field" {
  local scratch="$BATS_TEST_TMPDIR/scratch" toolkit event member_row role child_rows tolerance zero_lines
  cp -R "$FIXTURE" "$scratch"
  toolkit="$(node "$REPO_ROOT/.gaia/tests/audit-cost/measure-dispatch.mjs" --session "$scratch/session.jsonl" --rates "$RATES_FILE")"
  record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID"
  [ "$STATUS" -eq 0 ]
  event="$(cat "$LOG")"

  member_row="$(jq -c --arg id "$MEMBER_ID" '.dispatches[] | select(.agent_id == $id)' <<<"$toolkit")"
  zero_lines="$(jq -s '[.[] | select(.type == "assistant" and .message.usage != null)
    | select([.message.usage.input_tokens, .message.usage.cache_creation_input_tokens,
              .message.usage.cache_read_input_tokens, .message.usage.output_tokens] | add == 0)
    | .message.id] | unique | length' "$scratch/session/subagents/agent-$MEMBER_ID.jsonl")"
  [ "$(field "$event" '.own.calls')" = "$(( $(field "$member_row" '.calls') - zero_lines ))" ]
  [ "$(( $(field "$event" '.own.cache_write_5m_tokens') + $(field "$event" '.own.cache_write_1h_tokens') ))" = "$(field "$member_row" '[.per_call[].cache_write] | add')" ]
  [ "$(field "$event" '.own.cache_read_tokens')" = "$(field "$member_row" '[.per_call[].cache_read] | add')" ]
  [ "$(printf '%.3f' "$(field "$event" '.own.wall_s')")" = "$(printf '%.3f' "$(field "$member_row" '.wall_s')")" ]
  within "$(field "$event" '.own.dollars')" "$(field "$member_row" '.cost_usd')" 0.0000005
  within "$(field "$event" '.children_dollars')" "$(field "$member_row" '.children_cost_usd')" 0.0000005

  for role in specialist refuter other; do
    child_rows="$(jq -c --arg member "$MEMBER_ID" --arg role "$role" '
      .dispatches as $rows
      | ($rows | map(select(.parent_agent_id == $member) | .agent_id)) as $direct
      | [$rows[] | select(.agent_id != $member and (.parent_agent_id == $member or ((.parent_agent_id // "") as $parent | $direct | index($parent) != null)))
         | select((if .agent_type == "audit-rule-specialist" then "specialist" elif .agent_type == "audit-refuter" then "refuter" else "other" end) == $role)]' <<<"$toolkit")"
    [ "$(field "$event" ".children.$role.dispatches")" = "$(field "$child_rows" 'length')" ]
    [ "$(field "$event" ".children.$role.calls")" = "$(field "$child_rows" 'map(.calls) | add')" ]
    [ "$(field "$event" ".children.$role.cache_read_tokens")" = "$(field "$child_rows" '[.[].per_call[].cache_read] | add')" ]
    [ "$(field "$event" ".children.$role.longest_wall_s")" = "$(field "$child_rows" 'map(.wall_s) | max')" ]
    tolerance="$(awk -v n="$(field "$child_rows" 'length')" 'BEGIN { printf "%.7f", 0.0000005 * n }')"
    within "$(field "$event" ".children.$role.dollars")" "$(field "$child_rows" 'map(.cost_usd) | add')" "$tolerance"
  done
}

@test "report: delegates bytes and exit status to the report script" {
  local expected expected_status=0 actual actual_status=0
  record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID"
  [ "$(line_count)" = 1 ]
  expected="$(bash "$REPORT_SCRIPT" --root "$ROOT" 2>&1)" || expected_status=$?
  actual="$(bash "$SCRIPT" report --root "$ROOT" 2>&1)" || actual_status=$?
  [ -n "$expected" ]
  [ "$actual" = "$expected" ]
  [ "$actual_status" = "$expected_status" ]
  actual_status=0
  bash "$SCRIPT" report --root "$ROOT" --window 0 >/dev/null 2>&1 || actual_status=$?
  [ "$actual_status" -eq 2 ]
}

@test "usage: no subcommand or an unknown one exits 2, help exits 0" {
  local status_code=0
  bash "$SCRIPT" >/dev/null 2>&1 || status_code=$?
  [ "$status_code" -eq 2 ]
  status_code=0
  bash "$SCRIPT" frobnicate >/dev/null 2>&1 || status_code=$?
  [ "$status_code" -eq 2 ]
  status_code=0
  bash "$SCRIPT" --help >/dev/null 2>&1 || status_code=$?
  [ "$status_code" -eq 0 ]
}

# bats test_tags=whole-tree
@test "registration: the script is release-excluded and the registry names it only in prose" {
  local why
  grep -qxF ".gaia/scripts/audit-dispatch-cost.sh" "$REPO_ROOT/.gaia/release-exclude"
  why="$(jq -r '.entries[] | select(.id == "telemetry-audit-light-routing") | .why' "$REPO_ROOT/.gaia/state-registry.json")"
  [ -n "$why" ]
  grep -qF -- "dispatch-cost recorder" <<<"$why"
  grep -qF -- "cost report" <<<"$why"
  grep -qF -- "audit-dispatch-cost" <<<"$why" && return 1
  true
}
