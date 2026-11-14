#!/usr/bin/env bats
# Refusal guards of the test-design table library: verify, approve,
# record-security, amend and the requirement-key enumerator.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TABLE_CLI="$REPO_ROOT/.gaia/scripts/test-design/test-table.mjs"
  KEYS_SCRIPT="$REPO_ROOT/.gaia/scripts/spec/requirement-keys.sh"
  PLAN="$BATS_TEST_TMPDIR/plan"
  KEYS="$BATS_TEST_TMPDIR/keys.txt"
  MUTATE="$BATS_TEST_TMPDIR/mutate.mjs"
  mkdir -p "$PLAN"
  cat >"$MUTATE" <<'EOF'
import {readFileSync, writeFileSync} from 'node:fs';
const [file, body] = process.argv.slice(2);
const table = JSON.parse(readFileSync(file, 'utf8'));
new Function('t', body)(table);
writeFileSync(file, JSON.stringify(table, null, 2) + '\n');
EOF
}

mutate_table() {
  node "$MUTATE" "$PLAN/tests.json" "$1"
}

write_verify_fixture() {
  cat >"$PLAN/tests.json" <<'EOF'
{"schema": 1, "rows": [
  {"id": "T1", "source": "flow:alpha", "case": "alpha works", "file": "src/alpha.test.ts", "title": "alpha works", "layer": "unit", "task": "task-one", "action": "new", "security": "none"},
  {"id": "T2", "source": "success_criteria:0", "case": "beta refuses", "file": "src/beta.test.ts", "title": "beta refuses", "layer": "route", "task": "task-two", "action": "new", "security": "access"}
]}
EOF
  printf 'flow:alpha\nsuccess_criteria:0\n' >"$KEYS"
  printf 'schema: 1\n' >"$PLAN/TEST-DESIGN"
  printf '# one\n\n- Test: src/alpha.test.ts \xe2\x80\xba alpha works\n- Pin update: src/pinned.test.ts\n' >"$PLAN/task-one.md"
  printf '# two\n\n- Test: src/beta.test.ts \xe2\x80\xba beta refuses\n- Flow test (f): .playwright/flows/beta.spec.ts\n' >"$PLAN/task-two.md"
}

run_verify() {
  run node "$TABLE_CLI" verify --plan-dir "$PLAN" --keys "$KEYS"
}

# One verify refusal: build the fixture, break it with $1 (a shell snippet),
# and require exit 1 with $2 in the stderr.
expect_verify_refusal() {
  rm -rf "$PLAN"
  mkdir -p "$PLAN"
  write_verify_fixture
  eval "$1"
  run_verify
  if [ "$status" -ne 1 ]; then
    echo "case '$1': expected exit 1, got $status: $output" >&2
    return 1
  fi
  if ! grep -qF -- "$2" <<<"$output"; then
    echo "case '$1': stderr lacks '$2': $output" >&2
    return 1
  fi
}

@test "verify passes a complete table; a Pin update line needs no row" {
  write_verify_fixture
  run_verify
  [ "$status" -eq 0 ]
}

@test "verify refuses a missing or unparseable table" {
  expect_verify_refusal 'rm "$PLAN/tests.json"' 'tests.json is missing'
  expect_verify_refusal 'printf "{nope" >"$PLAN/tests.json"' 'not valid JSON'
}

@test "verify refuses a row missing each required field" {
  local field
  for field in id source case file title layer task action security; do
    expect_verify_refusal "mutate_table 'delete t.rows[0].$field'" "missing required field \"$field\""
  done
}

@test "verify refuses an illegal layer, action or security value" {
  expect_verify_refusal "mutate_table 't.rows[0].layer = \"mobile\"'" 'illegal layer'
  expect_verify_refusal "mutate_table 't.rows[0].action = \"rewrite\"'" 'illegal action'
  expect_verify_refusal "mutate_table 't.rows[0].security = \"high\"'" 'illegal security'
}

@test "verify refuses duplicate ids, shared tests without caseKeys and an extend row with no caseKey" {
  expect_verify_refusal "mutate_table 't.rows[1].id = \"T1\"'" 'duplicate id T1'
  expect_verify_refusal "mutate_table 't.rows[1].file = t.rows[0].file; t.rows[1].title = t.rows[0].title'" 'without distinct caseKeys'
  expect_verify_refusal "mutate_table 't.rows[0].action = \"extend\"'" 'an extend row needs a caseKey'
}

@test "verify refuses key and row source mismatches" {
  expect_verify_refusal 'printf "flow:gamma\n" >>"$KEYS"' 'requirement key flow:gamma has no row'
  expect_verify_refusal "mutate_table 't.rows[0].source = \"flow:stray\"'" 'unknown source flow:stray'
}

@test "verify refuses task-doc and table disagreements" {
  expect_verify_refusal 'printf -- "- Test: src/ghost.test.ts \xe2\x80\xba ghost\n" >>"$PLAN/task-one.md"' 'Test line has no row'
  expect_verify_refusal 'printf "# one\n" >"$PLAN/task-one.md"' 'has no Test line'
  expect_verify_refusal 'printf -- "see src/other.test.ts for more\n" >>"$PLAN/task-one.md"' 'outside a Test, Flow test or Pin update line'
}

# One amend fixture: an approved table with two security rows on distinct
# keys plus one plain row; the current table starts equal to it.
write_amend_fixture() {
  cat >"$PLAN/tests.json" <<'EOF'
{"schema": 1, "rows": [
  {"id": "T1", "source": "flow:alpha", "case": "a", "file": "a.test.ts", "title": "a", "layer": "route", "task": "task-one", "action": "new", "security": "access"},
  {"id": "T2", "source": "success_criteria:0", "case": "b", "file": "b.test.ts", "title": "b", "layer": "route", "task": "task-one", "action": "new", "security": "forgery"},
  {"id": "T3", "source": "success_criteria:1", "case": "c", "file": "c.test.ts", "title": "c", "layer": "unit", "task": "task-one", "action": "new", "security": "none"}
]}
EOF
  cp "$PLAN/tests.json" "$PLAN/tests.approved.json"
  AMEND_BEFORE="$(cat "$PLAN/tests.json")"
}

run_amend() {
  printf '%s' "$1" >"$BATS_TEST_TMPDIR/changes.json"
  run node "$TABLE_CLI" amend --plan-dir "$PLAN" --root "$BATS_TEST_TMPDIR" --changes "$BATS_TEST_TMPDIR/changes.json"
}

@test "amend refuses a security fold that loses a key and leaves the file unchanged" {
  write_amend_fixture
  run_amend '{"remove":["T2"]}'
  [ "$status" -eq 1 ]
  grep -qF -- 'checkpoint: success_criteria:0' <<<"$output"
  [ "$(cat "$PLAN/tests.json")" = "$AMEND_BEFORE" ]
}

@test "amend refuses a dropped security flag and leaves the file unchanged" {
  write_amend_fixture
  run_amend '{"replace":[{"id":"T1","source":"flow:alpha","case":"a","file":"a.test.ts","title":"a","layer":"route","task":"task-one","action":"new","security":"none"}]}'
  [ "$status" -eq 1 ]
  grep -qF -- 'security flag dropped on T1' <<<"$output"
  [ "$(cat "$PLAN/tests.json")" = "$AMEND_BEFORE" ]
}

@test "amend accepts a non-security fold and a security fold that keeps every key" {
  write_amend_fixture
  run_amend '{"remove":["T3"],"add":[{"id":"T4","source":"success_criteria:1","case":"c2","file":"c2.test.ts","title":"c2","layer":"unit","task":"task-one","action":"new","security":"none"}]}'
  [ "$status" -eq 0 ]
  grep -qF '"T4"' "$PLAN/tests.json"
  grep -qF '"T3"' "$PLAN/tests.json" && return 1

  write_amend_fixture
  run_amend '{"remove":["T1","T2"],"add":[{"id":"T5","source":"flow:alpha","case":"a2","file":"a2.test.ts","title":"a2","layer":"route","task":"task-one","action":"new","security":"access"},{"id":"T6","source":"success_criteria:0","case":"b2","file":"b2.test.ts","title":"b2","layer":"route","task":"task-one","action":"new","security":"forgery"}]}'
  [ "$status" -eq 0 ]
  grep -qF '"T5"' "$PLAN/tests.json"
  grep -qF '"T6"' "$PLAN/tests.json"
  true
}

@test "approve writes a byte-equal approved copy and a marker hash, then refuses a second approval" {
  write_verify_fixture
  run node "$TABLE_CLI" approve --plan-dir "$PLAN"
  [ "$status" -eq 0 ]
  cmp -s "$PLAN/tests.json" "$PLAN/tests.approved.json"
  local expected
  expected="$(node -e 'process.stdout.write(require("node:crypto").createHash("sha256").update(require("node:fs").readFileSync(process.argv[1])).digest("hex"))' "$PLAN/tests.approved.json")"
  grep -qxF "approved_sha256: $expected" "$PLAN/TEST-DESIGN"
  run node "$TABLE_CLI" approve --plan-dir "$PLAN"
  [ "$status" -eq 1 ]
  grep -qF 'already exists' <<<"$output"
}

@test "approve --auto holds a security retire row and not a non-security one" {
  write_verify_fixture
  mutate_table 't.rows[0].action = "retire"; t.rows[1].action = "retire"'
  run node "$TABLE_CLI" approve --plan-dir "$PLAN" --auto
  [ "$status" -eq 0 ]
  grep -qF 'held T2' <<<"$output"
  [ "$(node -e 'const t=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(t.rows.map((r)=>r.held??"-").join(","))' "$PLAN/tests.approved.json")" = "-,auto-mode" ]
  cmp -s "$PLAN/tests.json" "$PLAN/tests.approved.json"
}

@test "record-security refuses an absent test and records the signal of a present one" {
  write_verify_fixture
  local tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/src"
  run node "$TABLE_CLI" record-security --plan-dir "$PLAN" --root "$tree" --row T2
  [ "$status" -eq 1 ]
  grep -qF 'absent' <<<"$output"
  [ ! -e "$PLAN/security-tests.jsonl" ]

  cat >"$tree/src/beta.test.ts" <<'EOF'
import {expect, test} from 'vitest';

test('beta refuses', () => {
  expect(1).toBe(1);
});
EOF
  run node "$TABLE_CLI" record-security --plan-dir "$PLAN" --root "$tree" --row T2
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$PLAN/security-tests.jsonl" | tr -d ' ')" = "1" ]
  grep -qE '^\{"row":"T2","file":"src/beta.test.ts","title":"beta refuses","signal":"sha256:[0-9a-f]{64}"\}$' "$PLAN/security-tests.jsonl"
}

@test "requirement-keys prints the sorted key list for a SPEC and audit" {
  local spec="$BATS_TEST_TMPDIR/SPEC.md" audit="$BATS_TEST_TMPDIR/AUDIT.md"
  cat >"$spec" <<'EOF'
---
spec_id: SPEC-900
success_criteria:
  - first criterion
  - second criterion
    continued here
flows:
  - flow_id: FLOW-001
    slug: sign-in
    name: A user signs in.
    why: Sign-in gates the app.
    test_path: tests/sign-in.bats
scope_boundaries:
  always:
    - do the thing
  ask_first:
    - ask about the thing
  never:
    - never one
    - never two
clarifications:
  answered:
    - q: question one
      a: answer one
    - q: question two
      a: answer two
---
Body.
EOF
  cat >"$audit" <<'EOF'
# Audit

## Plan-time directives (no SPEC change)

1. First directive.
2. Second directive.

## Other section

3. Not a directive.
EOF
  run bash "$KEYS_SCRIPT" --spec "$spec" --audit "$audit"
  [ "$status" -eq 0 ]
  [ "$output" = "clarifications:0
clarifications:1
directive:1
directive:2
flow:sign-in
scope_boundaries:always:0
scope_boundaries:ask_first:0
scope_boundaries:never:0
scope_boundaries:never:1
success_criteria:0
success_criteria:1" ]

  printf 'no frontmatter\n' >"$BATS_TEST_TMPDIR/bare.md"
  run bash "$KEYS_SCRIPT" --spec "$BATS_TEST_TMPDIR/bare.md"
  [ "$status" -eq 2 ]

  run bash "$KEYS_SCRIPT" --description
  [ "$status" -eq 0 ]
  [ "$output" = "description" ]
}
