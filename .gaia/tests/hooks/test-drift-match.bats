#!/usr/bin/env bats
# Guards of the drift check's matching rule and refusals, on scratch git
# fixtures: what does not count as a match, the held retire row, an unplanned
# delete, the unmarked plan, the refusals, and the describe-rename pairing.
#
# GAIA_TEST_DRIFT_CHECK overrides the entry point so a scratch copy with a
# broken skip detector can prove the skip cases go red.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DRIFT_CHECK="${GAIA_TEST_DRIFT_CHECK:-$REPO_ROOT/.gaia/scripts/test-drift-check.sh}"
  TABLE_CLI="$REPO_ROOT/.gaia/scripts/test-design/test-table.mjs"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  PLAN="$BATS_TEST_TMPDIR/plan"
}

git_fixture() {
  git -C "$FIXTURE" -c user.name=fixture -c user.email=fixture@example.com -c commit.gpgsign=false "$@"
}

# write_file <repo-relative path> <content>
write_file() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  printf '%s\n' "$2" >"$FIXTURE/$1"
}

# start_fixture: a repo whose main holds what write_file wrote before it, then
# a feature branch.
start_fixture() {
  mkdir -p "$FIXTURE"
  git -C "$FIXTURE" init -q -b main
  : >"$FIXTURE/.keep"
  git_fixture add -A
  git_fixture commit -q -m base
  git_fixture checkout -q -b feature
}

reset_fixture() {
  rm -rf "$FIXTURE" "$PLAN"
}

# approve_rows <rows JSON array>: a marked, approved plan holding those rows.
approve_rows() {
  mkdir -p "$PLAN"
  printf '{"schema": 1, "rows": %s}\n' "$1" >"$PLAN/tests.json"
  printf 'schema: 1\n' >"$PLAN/TEST-DESIGN"
  node "$TABLE_CLI" approve --plan-dir "$PLAN"
}

row() {
  # row <id> <file> <title> <action> [security] [extra JSON fields]
  printf '{"id":"%s","source":"flow:alpha","case":"c","file":"%s","title":"%s","layer":"unit","task":"task-one","action":"%s","security":"%s"%s}' \
    "$1" "$2" "$3" "$4" "${5:-none}" "${6:-}"
}

classify() {
  run "$DRIFT_CHECK" classify --root "$FIXTURE" --plan-dir "$PLAN" --base main
}

suite_file() {
  printf "import {describe, expect, test} from 'vitest';\ndescribe('suite', () => {\n%s\n});" "$1"
}

PLAIN_TEST="  test('target', () => {
    expect(1).toBe(1);
  });"

# One not-a-match case: base content of the file (empty for none), head
# content, the row's action, security and extra fields, and the drift list the
# row's test must land in.
expect_not_a_match() {
  local name="$1" file="$2" base_content="$3" head_content="$4" action="$5" security="$6" extra="$7" lands_in="$8"
  local title='suite target'
  case "$file" in *.bats) title='target' ;; esac
  reset_fixture
  [ -z "$base_content" ] || write_file "$file" "$base_content"
  write_file src/control.test.ts "$(suite_file "$PLAIN_TEST")"
  start_fixture
  write_file "$file" "$head_content"
  approve_rows "[$(row T1 "$file" "$title" "$action" "$security" "$extra"),$(row T2 src/control.test.ts 'suite target' reuse)]" >/dev/null
  classify
  [ "$status" -eq 0 ] || { echo "$name: exit $status: $output" >&2; return 1; }
  jq -e '[.matched[].row] == ["T2"]' <<<"$output" >/dev/null || { echo "$name: control row not the only match: $output" >&2; return 1; }
  if [ "$lands_in" = "missing" ]; then
    jq -e '[.missing[].row] == ["T1"] and [.fixer[].row] == ["T1"]' <<<"$output" >/dev/null ||
      { echo "$name: T1 not missing: $output" >&2; return 1; }
  else
    jq -e --arg title "$title" '[.unplanned[].title] == [$title] and ([.evaluator[].title] | index($title) != null)' <<<"$output" >/dev/null ||
      { echo "$name: test not unplanned: $output" >&2; return 1; }
  fi
}

@test "a test that does not count, or whose action does not hold, never matches its row" {
  local changed_body="  test('target', () => {
    expect(2).toBe(2);
  });"
  local each_test="  test.each(['alpha', 'beta'])('target %s', (value) => {
    expect(value).toBeTruthy();
  });"
  local cases_run=0
  while IFS='|' read -r name file action security extra lands_in head_body; do
    [ -n "$name" ] || continue
    cases_run=$((cases_run + 1))
    local head_content base_content=''
    case "$file" in
      *.bats) head_content="$(printf '#!/usr/bin/env bats\n@test "target" {\n%s\n}' "$head_body")" ;;
      *) head_content="$(suite_file "$head_body")" ;;
    esac
    if [ "$name" = each-missing-case ]; then
      expect_each_missing "$(suite_file "$each_test")" || return 1
      continue
    fi
    if [ "$name" = reuse-changed ]; then
      base_content="$(suite_file "$PLAIN_TEST")"
      head_content="$(suite_file "$changed_body")"
    fi
    expect_not_a_match "$name" "$file" "$base_content" "$head_content" "$action" "$security" "$extra" "$lands_in" || return 1
  done <<'CASES'
todo|src/a.test.ts|new|none||missing|  test.todo('target');
skip|src/a.test.ts|new|none||missing|  test.skip('target', () => { expect(1).toBe(1); });
fixme|src/a.spec.ts|new|none||missing|  test.fixme('target', () => { expect(1).toBe(1); });
skipIf|src/a.test.ts|new|none||missing|  test.skipIf(true)('target', () => { expect(1).toBe(1); });
runIf|src/a.test.ts|new|none||missing|  test.runIf(false)('target', () => { expect(1).toBe(1); });
in-body-skip|src/a.spec.ts|new|none||missing|  test('target', () => { test.skip(); expect(1).toBe(1); });
bats-skip|tests/a.bats|new|none||missing|  skip "not yet"
empty-body|src/a.test.ts|new|none||missing|  test('target', () => {});
each-missing-case|src/a.test.ts|new|none||missing|
executor-security|src/a.test.ts|new|access||unplanned|  test('target', () => { expect(1).toBe(1); });
reuse-changed|src/a.test.ts|reuse|none||missing|
CASES
  [ "$cases_run" -eq 11 ] || { echo "ran $cases_run of 11 cases" >&2; return 1; }
}

# A row whose caseKey is absent from its test's case table is missing.
expect_each_missing() {
  reset_fixture
  write_file src/control.test.ts "$(suite_file "$PLAIN_TEST")"
  start_fixture
  write_file src/a.test.ts "$1"
  approve_rows "[$(row T1 src/a.test.ts 'suite target %s' new none ',"caseKey":"gamma"'),$(row T3 src/a.test.ts 'suite target %s' new none ',"caseKey":"alpha"'),$(row T2 src/control.test.ts 'suite target' reuse)]" >/dev/null
  classify
  [ "$status" -eq 0 ] || { echo "caseKey: exit $status: $output" >&2; return 1; }
  jq -e '[.missing[].row] == ["T1"] and ([.matched[].row] | sort) == ["T2", "T3"]' <<<"$output" >/dev/null ||
    { echo "caseKey: gamma not missing or alpha not matched: $output" >&2; return 1; }
}

@test "a held retire row whose test is present is matched and never sent to the fixer" {
  write_file src/a.test.ts "$(suite_file "$PLAIN_TEST")"
  start_fixture
  approve_rows "[$(row T1 src/a.test.ts 'suite target' retire access ',"held":"auto-mode"')]" >/dev/null
  classify
  [ "$status" -eq 0 ]
  jq -e '[.matched[].row] == ["T1"] and .fixer == [] and .missing == []' <<<"$output" >/dev/null
}

@test "a base test the branch deletes with no retire row is an unplanned delete, not evaluator work" {
  write_file src/a.test.ts "$(suite_file "$PLAIN_TEST
  test('gone', () => {
    expect(3).toBe(3);
  });")"
  start_fixture
  write_file src/a.test.ts "$(suite_file "$PLAIN_TEST")"
  approve_rows "[$(row T1 src/a.test.ts 'suite target' reuse)]" >/dev/null
  classify
  [ "$status" -eq 0 ]
  jq -e '.unplannedDeletes == [{"file":"src/a.test.ts","title":"suite gone"}] and .evaluator == []' <<<"$output" >/dev/null
}

@test "with no TEST-DESIGN marker, classify exits 2 naming it and security exits 0 silently" {
  start_fixture
  mkdir -p "$PLAN"
  classify
  [ "$status" -eq 2 ]
  grep -qF 'no TEST-DESIGN marker' <<<"$output"
  run "$DRIFT_CHECK" security --root "$FIXTURE" --plan-dir "$PLAN" --base main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "each unusable input is a refusal, exit 3 with its reason" {
  local break_step reason refusals_run=0
  while IFS='|' read -r break_step reason; do
    refusals_run=$((refusals_run + 1))
    reset_fixture
    write_file src/a.test.ts "$(suite_file "$PLAIN_TEST")"
    start_fixture
    approve_rows "[$(row T1 src/a.test.ts 'suite target' reuse)]" >/dev/null
    eval "$break_step"
    classify
    [ "$status" -eq 3 ] || { echo "'$break_step': expected 3, got $status: $output" >&2; return 1; }
    grep -qF -- "$reason" <<<"$output" || { echo "'$break_step': no '$reason' in: $output" >&2; return 1; }
  done <<'CASES'
rm "$PLAN/tests.approved.json"|approved copy: tests.approved.json is missing
printf ' ' >>"$PLAN/tests.approved.json"|does not match the marker
printf '{nope' >"$PLAN/tests.json"|unreadable table
write_file src/a.test.ts "$(suite_file "  test(\`target \${1}\`, () => { expect(1).toBe(1); });")"|not a string literal
write_file src/a.test.ts "$(suite_file "$PLAIN_TEST"$'\n'"$PLAIN_TEST")"|duplicate full name "suite target"
CASES
  [ "$refusals_run" -eq 5 ] || { echo "ran $refusals_run of 5 refusals" >&2; return 1; }
}

@test "a describe rename pairs the row with its renamed test instead of missing plus unplanned" {
  write_file src/a.test.ts "$(suite_file "$PLAIN_TEST")"
  start_fixture
  write_file src/a.test.ts "$(suite_file "$PLAIN_TEST" | sed "s/describe('suite'/describe('renamed'/")"
  approve_rows "[$(row T1 src/a.test.ts 'suite target' reuse)]" >/dev/null
  classify
  [ "$status" -eq 0 ]
  jq -e '.likelyRenames == [{"row":"T1","file":"src/a.test.ts","title":"suite target","renamedTo":"renamed target"}]
    and .missing == [] and .unplanned == [] and .unplannedDeletes == []' <<<"$output" >/dev/null
}
