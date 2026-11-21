#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-dispatch-cost.sh beyond a dispatch that ran:
# members recorded as not dispatched, the adopter gate, the project-folder
# scope of the transcript lookup, the never-block contract, parity with the
# committed toolkit, `report` delegation and the release registration.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# The sandbox repository is built once per file and copied per test, with its
# bare origin beside it as catchup_add_origin lays it out.
setup_file() {
  local repo_root template
  repo_root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$repo_root/.gaia/tests/helpers/audit-roster.sh"
  . "$repo_root/.gaia/tests/helpers/catchup-fixture.sh"
  template="$BATS_FILE_TMPDIR/template-root"
  mkdir -p "$template/.gaia" "$template/.claude/rules/maintainers"
  printf '1.6.1\n' > "$template/.gaia/VERSION"
  git -C "$template" init --quiet --initial-branch=main
  git -C "$template" config user.email "test@example.com"
  git -C "$template" config user.name "Test"
  git -C "$template" config commit.gpgsign false
  echo "# readme" > "$template/README.md"
  seed_audit_roster "$template"
  git -C "$template" add .gaia/audit-ci.yml .gaia/VERSION README.md
  git -C "$template" commit --quiet -m "init"
  git -C "$template" remote add origin "$BATS_FILE_TMPDIR/placeholder-origin.git"
  catchup_add_origin "$template" main --feature feat/dispatch-cost
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/audit-dispatch-cost.sh"
  REPORT_SCRIPT="$REPO_ROOT/.gaia/scripts/audit-dispatch-cost-report.sh"
  FIXTURE="$REPO_ROOT/.gaia/tests/audit-cost/fixtures/dispatch-cost"
  [ -f "$SCRIPT" ]
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  MEMBER="code-audit-frontend"
  MEMBER_ID=a0000000000000001
  SESSION_ID=11111111-2222-3333-4444-555555555555
  ROOT="$BATS_TEST_TMPDIR/root"
  cp -R "$BATS_FILE_TMPDIR/template-root" "$ROOT"
  cp -R "$BATS_FILE_TMPDIR/template-root.catchup-origin.git" "$ROOT.catchup-origin.git"
  git -C "$ROOT" remote set-url origin "$ROOT.catchup-origin.git"
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

# run_recorded <command...>: run it, keeping its status, stdout and stderr.
run_recorded() {
  STATUS=0
  OUT="$BATS_TEST_TMPDIR/record.out"
  ERR="$BATS_TEST_TMPDIR/record.err"
  "$@" >"$OUT" 2>"$ERR" || STATUS=$?
}

record() {
  run_recorded bash "$SCRIPT" record --root "$ROOT" "$@"
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

@test "record refuses malformed arguments and appends nothing: bad, empty or missing reason, agent id with not_dispatched, light reviewer not_dispatched, several members with an agent id, ../x and glob agent ids, slash in member, missing member, empty agent id, unknown kind, unknown flag, no --root" {
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
  run_recorded bash "$SCRIPT" record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID"
  expect_nothing_recorded
}

@test "never block: jq off the PATH, an unwritable telemetry directory and an unloadable rates override each exit 0 with nothing recorded and at most one stderr line, rates named" {
  local empty_bin="$BATS_TEST_TMPDIR/empty-bin"

  # jq off the PATH
  mkdir -p "$empty_bin"
  run_recorded env PATH="$empty_bin" /bin/bash "$SCRIPT" record --root "$ROOT" --kind member --member "$MEMBER" --agent-id "$MEMBER_ID"
  expect_nothing_recorded

  # an unwritable telemetry directory
  mkdir -p "$TELEMETRY_DIRECTORY"
  chmod 555 "$TELEMETRY_DIRECTORY"
  record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID"
  chmod 755 "$TELEMETRY_DIRECTORY"
  expect_nothing_recorded

  # a rates override that cannot load
  printf 'not json {\n' >"$TELEMETRY_DIRECTORY/token-rates.override.json"
  record --kind member --member "$MEMBER" --agent-id "$MEMBER_ID"
  expect_nothing_recorded
  [ "$(wc -l <"$ERR" | tr -d ' ')" = 1 ]
  grep -qi -- "rates" "$ERR"
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

# bats test_tags=protected
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
@test "registration: the dispatch-cost scripts are release-excluded and the registry names the recorder only in prose" {
  local why excluded
  for excluded in audit-dispatch-cost.sh audit-dispatch-cost-lib.sh audit-dispatch-cost-report.sh; do
    grep -qxF ".gaia/scripts/$excluded" "$REPO_ROOT/.gaia/release-exclude" || { echo "not release-excluded: $excluded" >&2; return 1; }
  done
  why="$(jq -r '.entries[] | select(.id == "telemetry-audit-light-routing") | .why' "$REPO_ROOT/.gaia/state-registry.json")"
  [ -n "$why" ]
  grep -qF -- "dispatch-cost recorder" <<<"$why"
  grep -qF -- "cost report" <<<"$why"
  grep -qF -- "audit-dispatch-cost" <<<"$why" && return 1
  true
}
