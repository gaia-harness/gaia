#!/usr/bin/env bats
# The security-row merge gate end to end: a merge is allowed with no plan run or
# no marker, allowed while an approved security row has its security-writer
# test, denied for a non-test and for a hollow verdict until a
# fresh keep clears it, and denied for a removed test until the maintainer
# types a grant in an interactive session. Every scenario runs the real gate
# and the real grant recorder on a scratch git repo whose feature branch a
# plan run claims through its RUNNING sentinel.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/tests/hooks/test-design-merge-gate.bats < /dev/null`.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GATE="$REPO_ROOT/.claude/hooks/test-design-merge-gate.sh"
  GRANT="$REPO_ROOT/.claude/hooks/test-row-grant.sh"
  TABLE_CLI="$REPO_ROOT/.gaia/scripts/test-design/test-table.mjs"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  NOTEBOOK_DIRECTORY=".note""book"
  PLAN="$FIXTURE/$NOTEBOOK_DIRECTORY/specs/feature-one/plan"
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  export WORTHINESS_LEDGER_PATH="$BATS_TEST_TMPDIR/worthiness.jsonl"
  rm -f "$WORTHINESS_LEDGER_PATH"
  init_repo
}

git_fixture() {
  git -C "$FIXTURE" -c user.name=fixture -c user.email=fixture@example.com -c commit.gpgsign=false "$@"
}

init_repo() {
  mkdir -p "$FIXTURE"
  git -C "$FIXTURE" init -q -b main
  printf '%s/\n.gaia/local/\n' "$NOTEBOOK_DIRECTORY" >"$FIXTURE/.gitignore"
  git_fixture add -A
  git_fixture commit -q -m base
  git_fixture checkout -q -b feature
}

# stage_plan <file> <title>: a marked, approved plan run claiming the branch,
# whose one security row names that test.
stage_plan() {
  mkdir -p "$PLAN"
  printf 'branch: feature\nslug: plan\nmode: feature-branch\n' >"$PLAN/RUNNING"
  printf '{"schema": 1, "rows": [{"id":"T1","source":"flow:alpha","case":"c","file":"%s","title":"%s","layer":"unit","task":"task-one","action":"new","security":"access"}]}\n' \
    "$1" "$2" >"$PLAN/tests.json"
  printf 'schema: 1\n' >"$PLAN/TEST-DESIGN"
  node "$TABLE_CLI" approve --plan-dir "$PLAN" >/dev/null
}

# write_test <body of the test file>: commit it on the branch.
write_test() {
  mkdir -p "$FIXTURE/src"
  printf '%s\n' "$1" >"$FIXTURE/src/guard.test.ts"
  git_fixture add -A
  git_fixture commit -q -m feature
}

# authored: the security writer records the row's test as it stands.
authored() {
  node "$TABLE_CLI" record-security --plan-dir "$PLAN" --root "$FIXTURE" --row T1 >/dev/null
}

run_gate() {
  local payload
  payload="$(jq -n --arg c "gh pr merge 7 --squash" --arg d "$FIXTURE" \
    '{session_id: "s", cwd: $d, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}')"
  invoke_hook "$payload" "$GATE"
}

assert_denied_with() {
  assert_denied_by_json || { echo "not denied: $output" >&2; return 1; }
  grep -qF -- "$1" <<<"$output" || { echo "deny lacks '$1': $output" >&2; return 1; }
}

# ledger_line <verdict> <file>: a worthiness verdict at the test's current signal.
ledger_line() {
  local signal
  signal="$(jq -r '.signal' "$PLAN/security-tests.jsonl" | tail -n 1)"
  jq -nc --arg v "$1" --arg s "$signal" --arg f "${2:-src/guard.test.ts}" \
    '{file: $f, fullName: "guard T1", signal: $s, verdict: $v}' >>"$WORTHINESS_LEDGER_PATH"
}

grant_prompt() {
  printf '{"entrypoint":"cli"}\n' >"$TRANSCRIPT"
  local payload
  payload="$(jq -n --arg p "$1" --arg d "$FIXTURE" --arg t "$TRANSCRIPT" \
    '{session_id: "s", transcript_path: $t, cwd: $d, hook_event_name: "UserPromptSubmit", prompt: $p}')"
  run env CLAUDE_CODE_ENTRYPOINT=cli bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$GRANT"
}

REAL_TEST="import {describe, expect, test} from 'vitest';
describe('guard', () => {
  test('T1', () => {
    expect(1).toBe(1);
  });
});"

@test "a branch with no plan run, and a plan with no marker, allow the merge" {
  run_gate
  assert_allowed_by_json
  stage_plan src/guard.test.ts 'guard T1'
  rm "$PLAN/TEST-DESIGN"
  run_gate
  assert_allowed_by_json
}

@test "an approved security row whose authored test is real and kept allows the merge" {
  write_test "$REAL_TEST"
  stage_plan src/guard.test.ts 'guard T1'
  authored
  ledger_line keep
  run_gate
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "a security row whose authored test is a non-test denies, naming the row" {
  write_test "import {describe, expect, test} from 'vitest';
describe('guard', () => {
  test.skip('T1', () => { expect(1).toBe(1); });
});"
  stage_plan src/guard.test.ts 'guard T1'
  authored
  ledger_line keep
  run_gate
  assert_denied_with "T1"
}

@test "an uncommitted security test does not satisfy the row" {
  mkdir -p "$FIXTURE/src"
  printf '%s\n' "$REAL_TEST" >"$FIXTURE/src/guard.test.ts"
  stage_plan src/guard.test.ts 'guard T1'
  authored
  ledger_line keep
  run_gate
  assert_denied_with "T1: no-matching-test" || return 1
  git_fixture add -A
  git_fixture commit -q -m feature
  run_gate
  assert_allowed_by_json
}

@test "a bats skip denies the row" {
  mkdir -p "$FIXTURE/tests"
  printf '#!/usr/bin/env bats\n\n@test "guard T1" {\n  skip "later"\n  [ 1 -eq 1 ]\n}\n' >"$FIXTURE/tests/guard.bats"
  git_fixture add -A
  git_fixture commit -q -m feature
  stage_plan tests/guard.bats 'guard T1'
  authored
  ledger_line keep tests/guard.bats
  run_gate
  assert_denied_with "T1"
}

@test "a hollow verdict denies until a fresh keep at the same signal clears it" {
  write_test "$REAL_TEST"
  stage_plan src/guard.test.ts 'guard T1'
  authored
  ledger_line fix
  run_gate
  assert_denied_with "T1: hollow" || return 1
  ledger_line keep
  run_gate
  assert_allowed_by_json
}

@test "a removed test denies until a typed grant names the row" {
  write_test "$REAL_TEST"
  stage_plan src/guard.test.ts 'guard T1'
  authored
  ledger_line keep
  git_fixture rm -q src/guard.test.ts
  git_fixture commit -q -m remove
  run_gate
  assert_denied_with "T1: no-matching-test" || return 1
  grant_prompt "test-row-grant T1"
  grep -qF -- "Recorded: test-row-grant T1" <<<"$output"
  run_gate
  assert_allowed_by_json
}
