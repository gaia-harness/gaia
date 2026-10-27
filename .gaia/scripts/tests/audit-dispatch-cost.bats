#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-dispatch-cost.sh `record` on a dispatch that
# ran: the member and light reviewer events, call dedup, unpriced and mixed
# models, the missing, unparsed and unlinked states, the bounded finish wait,
# the worktree project folders and the newest-match rule. The not-dispatched,
# adopter-gate, lookup-scope, never-block, parity, delegation and registration
# cases are in audit-dispatch-cost-states.bats.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$REPO_ROOT/.gaia/tests/helpers/audit-roster.sh"
  SCRIPT="$REPO_ROOT/.gaia/scripts/audit-dispatch-cost.sh"
  TELEMETRY_SCRIPT="$REPO_ROOT/.gaia/scripts/audit-light-telemetry.sh"
  FIXTURE="$REPO_ROOT/.gaia/tests/audit-cost/fixtures/dispatch-cost"
  [ -f "$SCRIPT" ]
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  MEMBER="code-audit-frontend"
  MEMBER_ID=a0000000000000001
  LIGHT_ID=a0000000000000008
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
  printf '# maintainer rule\n' > "$ROOT/.claude/rules/maintainers/harness-triage-threshold.md"
  LOG="$ROOT/.gaia/local/telemetry/audit-light-routing.jsonl"

  . "$REPO_ROOT/.gaia/scripts/main-root-lib.sh"
  . "$REPO_ROOT/.gaia/scripts/usage-lib.sh"
  . "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh"
  ENCODED="$(gaia_usage_encode_path "$(gaia_resolve_main_root "$ROOT")")"
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  export GAIA_TALLY_PROJECTS_ROOT="$PROJECTS"
  export GAIA_DISPATCH_COST_FINISH_WAIT_SECONDS=1
  install_session "$ENCODED" "$FIXTURE"
}

teardown() {
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# install_session <project-folder> <fixture-copy>: the session as Claude Code
# lays it out, <projects>/<folder>/<session>.jsonl beside <session>/subagents.
install_session() {
  mkdir -p "$PROJECTS/$1/$SESSION_ID"
  cp "$2/session.jsonl" "$PROJECTS/$1/$SESSION_ID.jsonl"
  cp -R "$2/session/subagents" "$PROJECTS/$1/$SESSION_ID/subagents"
  SUBAGENTS="$PROJECTS/$1/$SESSION_ID/subagents"
}

# scratch_fixture: a private copy of the fixture, in SCRATCH, to edit before
# install_session replaces the session in the main project folder.
scratch_fixture() {
  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  rm -rf "$SCRATCH" "$PROJECTS"
  cp -R "$FIXTURE" "$SCRATCH"
}

# record <args...>: STATUS, OUT and ERR of one recorder call.
record() {
  STATUS=0
  OUT="$BATS_TEST_TMPDIR/record.out"
  ERR="$BATS_TEST_TMPDIR/record.err"
  bash "$SCRIPT" record --root "$ROOT" "$@" >"$OUT" 2>"$ERR" || STATUS=$?
}

record_member() {
  record --kind member --member "$MEMBER" --agent-id "${1:-$MEMBER_ID}"
}

line_count() {
  if [ -f "$LOG" ]; then wc -l <"$LOG" | tr -d ' '; else echo 0; fi
}

# expect_one_event: exit 0, empty stdout, exactly one appended line, in EVENT.
expect_one_event() {
  [ "$STATUS" -eq 0 ]
  [ ! -s "$OUT" ]
  [ "$(line_count)" = 1 ]
  EVENT="$(tail -n 1 "$LOG")"
}

field() {
  jq -r "$2" <<<"$1"
}

# set_meta <agent-id> <json>
set_meta() {
  printf '%s\n' "$2" >"$SUBAGENTS/agent-$1.meta.json"
}

@test "member event: keys equal member-result's, figures equal the library's" {
  local expected_own expected_children result_event
  record_member
  expect_one_event
  bash "$TELEMETRY_SCRIPT" member-result --root "$ROOT" --member "$MEMBER"
  result_event="$(grep '"event":"member_result"' "$LOG")"
  [ "$(field "$EVENT" '.event')" = dispatch_cost ]
  [ "$(field "$EVENT" '.kind')" = member ]
  [ "$(field "$EVENT" '.agent_type')" = code-audit-frontend ]
  [ "$(field "$EVENT" '.member')" = "$MEMBER" ]
  [ "$(field "$EVENT" '.agent_id')" = "$MEMBER_ID" ]
  [ "$(field "$EVENT" '.branch')" = "$(field "$result_event" '.branch')" ]
  [ "$(field "$EVENT" '.branch')" = "$(gaia_branch_slug "$ROOT")" ]
  [ "$(field "$EVENT" '.digest')" = "$(field "$result_event" '.digest')" ]
  [ "$(field "$EVENT" '.tree')" = "$(field "$result_event" '.tree')" ]
  [ "$(field "$EVENT" '.tree')" = "$(git -C "$ROOT" rev-parse 'HEAD^{tree}')" ]
  [ "$(field "$EVENT" '.state')" = ok ]
  [ "$(field "$EVENT" '.reason')" = null ]
  [ "$(field "$EVENT" '.children_state')" = ok ]
  [ "$(field "$EVENT" '.children.other.dispatches')" = 2 ]
  [ "$(field "$EVENT" '.schema')" = 1 ]
  [ "$(field "$EVENT" '.claude_code_version')" = 2.1.304 ]
  [ "$(field "$EVENT" '.finish')" = finished ]
  [ "$(field "$EVENT" '.incomplete')" = false ]
  [ -n "$(field "$EVENT" '.at')" ]

  . "$REPO_ROOT/.gaia/scripts/audit-dispatch-cost-lib.sh"
  gaia_rates_load "" "$REPO_ROOT/.gaia/scripts/token-rates.json"
  expected_own="$(gaia_dispatch_cost_measure "$SUBAGENTS" "$MEMBER_ID" "$GAIA_RATES_JSON" | jq -S -c '.own')"
  expected_children="$(gaia_dispatch_cost_measure "$SUBAGENTS" "$MEMBER_ID" "$GAIA_RATES_JSON" | jq -S -c '.children')"
  [ "$(field "$EVENT" '.own' | jq -S -c .)" = "$expected_own" ]
  [ "$(field "$EVENT" '.children' | jq -S -c .)" = "$expected_children" ]
}

@test "dedup: the event counts a repeated call once with its last block" {
  record_member
  expect_one_event
  [ "$(field "$EVENT" '.own.calls')" = 4 ]
  [ "$(field "$EVENT" '.own.output_tokens')" = 652 ]
}

@test "unpriced: an unrated model keeps every figure and nulls own dollars" {
  scratch_fixture
  sed 's/claude-opus-5-5/claude-unrated-9/g' "$SCRATCH/session/subagents/agent-$MEMBER_ID.jsonl" >"$SCRATCH/member.new"
  mv "$SCRATCH/member.new" "$SCRATCH/session/subagents/agent-$MEMBER_ID.jsonl"
  install_session "$ENCODED" "$SCRATCH"
  record_member
  expect_one_event
  [ "$(field "$EVENT" '.state')" = ok ]
  [ "$(field "$EVENT" '.own.calls')" = 4 ]
  [ "$(field "$EVENT" '.own.output_tokens')" = 652 ]
  [ "$(field "$EVENT" '.own.dollars')" = null ]
  [ "$(field "$EVENT" '.own.unpriced | join(",")')" = claude-unrated-9 ]
}

@test "missing: no transcript is transcript_missing with the keys set and no wait" {
  local started finished
  unset GAIA_DISPATCH_COST_FINISH_WAIT_SECONDS
  started="$(date +%s)"
  record --kind member --member "$MEMBER" --agent-id a00000000000000aa
  finished="$(date +%s)"
  expect_one_event
  [ "$((finished - started))" -le 2 ]
  [ "$(field "$EVENT" '.state')" = transcript_missing ]
  [ "$(field "$EVENT" '[.member, .kind, .agent_id, .branch, .digest, .tree] | map(. != null and . != "") | all')" = true ]
  [ "$(field "$EVENT" '[.agent_type, .incomplete, .finish, .claude_code_version, .own, .children_state, .children, .children_dollars] | map(. == null) | all')" = true ]
}

@test "finish wait: finished false waits the bound and records an incomplete timeout" {
  local started finished
  set_meta "$MEMBER_ID" '{"agentType":"code-audit-frontend","finished":false}'
  started="$(date +%s)"
  record_member
  finished="$(date +%s)"
  expect_one_event
  [ "$((finished - started))" -ge 1 ]
  [ "$((finished - started))" -lt 3 ]
  [ "$(field "$EVENT" '.state')" = ok ]
  [ "$(field "$EVENT" '.own.calls')" = 4 ]
  [ "$(field "$EVENT" '.incomplete')" = true ]
  [ "$(field "$EVENT" '.finish')" = timeout ]

  rm -f "$LOG"
  set_meta "$MEMBER_ID" '{"agentType":"code-audit-frontend"}'
  record_member
  expect_one_event
  [ "$(field "$EVENT" '.own.calls')" = 4 ]
  [ "$(field "$EVENT" '.incomplete')" = true ]
  [ "$(field "$EVENT" '.finish')" = timeout ]
}

@test "finish wait: the default bound is ten seconds" {
  local started finished
  unset GAIA_DISPATCH_COST_FINISH_WAIT_SECONDS
  set_meta "$MEMBER_ID" '{"agentType":"code-audit-frontend","finished":false}'
  started="$(date +%s)"
  record_member
  finished="$(date +%s)"
  expect_one_event
  [ "$((finished - started))" -ge 10 ]
  [ "$((finished - started))" -le 12 ]
  [ "$(field "$EVENT" '.finish')" = timeout ]
}

@test "finish wait: a meta that flips to finished ends the wait early" {
  local started finished
  export GAIA_DISPATCH_COST_FINISH_WAIT_SECONDS=5
  set_meta "$MEMBER_ID" '{"agentType":"code-audit-frontend","finished":false}'
  (
    sleep 0.3
    printf '%s\n' '{"agentType":"code-audit-frontend","finished":true}' >"$SUBAGENTS/flip.tmp"
    mv "$SUBAGENTS/flip.tmp" "$SUBAGENTS/agent-$MEMBER_ID.meta.json"
  ) &
  started="$(date +%s)"
  record_member
  finished="$(date +%s)"
  wait
  expect_one_event
  [ "$((finished - started))" -le 2 ]
  [ "$(field "$EVENT" '.incomplete')" = false ]
  [ "$(field "$EVENT" '.finish')" = finished ]
}

@test "finish: an absent meta is meta_missing and a torn one is meta_unparsed" {
  rm -f "$SUBAGENTS/agent-$MEMBER_ID.meta.json"
  record_member
  expect_one_event
  [ "$(field "$EVENT" '.finish')" = meta_missing ]
  [ "$(field "$EVENT" '.incomplete')" = true ]
  [ "$(field "$EVENT" '.own.calls')" = 4 ]

  rm -f "$LOG"
  printf '{"agentType": "code-au\n' >"$SUBAGENTS/agent-$MEMBER_ID.meta.json"
  record_member
  expect_one_event
  [ "$(field "$EVENT" '.finish')" = meta_unparsed ]
  [ "$(field "$EVENT" '.incomplete')" = true ]
}

@test "light reviewer: kind, reviewed member, own figures and an empty children object" {
  record --kind light_reviewer --member "$MEMBER" --agent-id "$LIGHT_ID"
  expect_one_event
  [ "$(field "$EVENT" '.kind')" = light_reviewer ]
  [ "$(field "$EVENT" '.member')" = "$MEMBER" ]
  [ "$(field "$EVENT" '.agent_type')" = audit-light-reviewer ]
  [ "$(field "$EVENT" '.state')" = ok ]
  [ "$(field "$EVENT" '.own.calls')" = 2 ]
  [ "$(field "$EVENT" '.children_state')" = ok ]
  [ "$(field "$EVENT" '.children')" = "{}" ]
}

@test "unparsed: a wholly non-JSON transcript is transcript_unparsed with null figures" {
  scratch_fixture
  printf 'not json\nstill not json\n' >"$SCRATCH/session/subagents/agent-$MEMBER_ID.jsonl"
  install_session "$ENCODED" "$SCRATCH"
  record_member
  expect_one_event
  [ "$(field "$EVENT" '.state')" = transcript_unparsed ]
  [ "$(field "$EVENT" '.finish')" = finished ]
  [ "$(field "$EVENT" '[.own, .children_state, .children, .children_dollars] | map(. == null) | all')" = true ]
  [ "$(field "$EVENT" '.member')" = "$MEMBER" ]
}

@test "mixed models: one unrated specialist nulls its role dollars only" {
  scratch_fixture
  sed 's/claude-sonnet-5-5/claude-unrated-9/g' "$SCRATCH/session/subagents/agent-a0000000000000002.jsonl" >"$SCRATCH/specialist.new"
  mv "$SCRATCH/specialist.new" "$SCRATCH/session/subagents/agent-a0000000000000002.jsonl"
  install_session "$ENCODED" "$SCRATCH"
  record_member
  expect_one_event
  [ "$(field "$EVENT" '.children.specialist.models | join(",")')" = "claude-sonnet-5-5,claude-unrated-9" ]
  [ "$(field "$EVENT" '.children.specialist.dollars')" = null ]
  [ "$(field "$EVENT" '.children.specialist.unpriced | join(",")')" = claude-unrated-9 ]
  [ "$(field "$EVENT" '.children_dollars')" = null ]
  [ "$(field "$EVENT" '.own.dollars | type')" = number ]
  [ "$(field "$EVENT" '.children.refuter.dollars | type')" = number ]
  [ "$(field "$EVENT" '.children.other.dollars | type')" = number ]
}

@test "worktree folder: a session under a worktree project folder is found" {
  rm -rf "$PROJECTS"
  install_session "$ENCODED--claude-worktrees-feat-x" "$FIXTURE"
  record_member
  expect_one_event
  [ "$(field "$EVENT" '.state')" = ok ]
  [ "$(field "$EVENT" '.own.calls')" = 4 ]
}

@test "linkage: metas without a parent leave own figures and unparsed children" {
  local name
  for name in a0000000000000002 a0000000000000003; do
    jq -c 'del(.parentAgentId)' "$SUBAGENTS/agent-$name.meta.json" >"$SUBAGENTS/meta.new"
    mv "$SUBAGENTS/meta.new" "$SUBAGENTS/agent-$name.meta.json"
  done
  record_member
  expect_one_event
  [ "$(field "$EVENT" '.state')" = ok ]
  [ "$(field "$EVENT" '.own.calls')" = 4 ]
  [ "$(field "$EVENT" '.children_state')" = unparsed ]
  [ "$(field "$EVENT" '.children')" = null ]
  [ "$(field "$EVENT" '.children_dollars')" = null ]
}

@test "newest match: the same agent id under two folders takes the newer file's figures" {
  local worktree_session="$PROJECTS/$ENCODED--claude-worktrees-feat-x/$SESSION_ID"
  mkdir -p "$worktree_session"
  cp -R "$SUBAGENTS" "$worktree_session/subagents"
  grep -v '"id":"msg_m3"' "$SUBAGENTS/agent-$MEMBER_ID.jsonl" >"$worktree_session/subagents/member.new"
  mv "$worktree_session/subagents/member.new" "$worktree_session/subagents/agent-$MEMBER_ID.jsonl"
  touch -t 202601010000 "$SUBAGENTS/agent-$MEMBER_ID.jsonl"
  touch -t 202701010000 "$worktree_session/subagents/agent-$MEMBER_ID.jsonl"
  record_member
  expect_one_event
  [ "$(field "$EVENT" '.own.calls')" -lt 4 ]

  rm -f "$LOG"
  touch -t 202701010000 "$SUBAGENTS/agent-$MEMBER_ID.jsonl"
  touch -t 202601010000 "$worktree_session/subagents/agent-$MEMBER_ID.jsonl"
  record_member
  expect_one_event
  [ "$(field "$EVENT" '.own.calls')" = 4 ]
}
