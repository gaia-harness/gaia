#!/usr/bin/env bats
# verify's and amend's per-case kind check: a flagged row with no caseKey that
# runs a test lists each case's kind in `caseKinds`, and a row whose cases carry
# two kinds, or one kind other than its flag, is refused.

# bats file_tags=installed-dependencies

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TABLE_CLI="$REPO_ROOT/.gaia/scripts/test-design/test-table.mjs"
  REPLANNED_CLI="$REPO_ROOT/.gaia/scripts/test-design/replanned-rows.mjs"
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
  printf 'success_criteria:0\n' >"$KEYS"
  printf 'schema: 1\n' >"$PLAN/TEST-DESIGN"
  printf '# members\n\n- Test: src/remove.test.ts \xe2\x80\xba removes the account the URL names whatever id is posted\n' >"$PLAN/task-members.md"
}

# A member may remove another member's account but never their own, and the
# server takes the target from the URL, never a posted field. One keyless
# forgery row holds both cases: the self-removal refusal is access, the
# ignored posted id is forgery.
write_mixed_table() {
  cat >"$PLAN/tests.json" <<'EOF'
{"schema": 1, "rows": [
  {"id": "T1", "source": "success_criteria:0",
   "case": "a member posting remove for their own account with another id in the body is refused and nothing changes; a member posting remove for another account with their own id in the body removes the URL's account",
   "file": "src/remove.test.ts", "title": "removes the account the URL names whatever id is posted", "layer": "route", "task": "task-members", "action": "new", "security": "forgery",
   "caseKinds": [
     {"case": "remove own account, another id posted: refused, nothing changes", "kind": "access"},
     {"case": "remove another account, own id posted: the URL's account is removed", "kind": "forgery"}]}
]}
EOF
}

# The same row narrowed to its forgery case alone: verify passes it.
write_forgery_table() {
  write_mixed_table
  mutate_table '
    t.rows[0].case = "a member posting remove for another account with their own id in the body removes the URL account";
    t.rows[0].caseKinds = [t.rows[0].caseKinds[1]];'
}

mutate_table() {
  node "$MUTATE" "$PLAN/tests.json" "$1"
}

verify() {
  run node "$TABLE_CLI" verify --plan-dir "$PLAN" --keys "$KEYS"
}

# expect_verify_refusal <mutation> <message>: verify exits 1 printing message.
expect_verify_refusal() {
  write_forgery_table
  mutate_table "$1"
  verify
  [ "$status" -eq 1 ] || { echo "accepted after: $1" >&2; return 1; }
  grep -qF -- "$2" <<<"$output" || { echo "expected '$2' after: $1, got: $output" >&2; return 1; }
}

@test "verify refuses a row whose cases carry two kinds and passes it narrowed to one" {
  write_mixed_table
  verify
  [ "$status" -eq 1 ]
  grep -qxF 'test-table: row T1 holds cases of kinds access, forgery; give each kind its own row' <<<"$output" || { echo "$output" >&2; return 1; }
  write_forgery_table
  verify
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "verify refuses a flagged keyless row with no caseKinds and names a flag that disagrees with its one kind" {
  expect_verify_refusal 'delete t.rows[0].caseKinds' 'row T1: a flagged row with no caseKey needs caseKinds'
  expect_verify_refusal 't.rows[0].security = "access"' 'row T1: its caseKinds are forgery but its security is access; a flag change updates both'
  expect_verify_refusal 't.rows[0].security = "none"' 'row T1: its caseKinds are forgery but its security is none'
}

@test "verify refuses each malformed caseKinds value" {
  expect_verify_refusal 't.rows[0].caseKinds = []' 'row T1: caseKinds is not a non-empty array'
  expect_verify_refusal 't.rows[0].caseKinds = "forgery"' 'row T1: caseKinds is not a non-empty array'
  expect_verify_refusal 't.rows[0].caseKinds = ["forgery"]' 'row T1 caseKinds #1 is not an object'
  expect_verify_refusal 't.rows[0].caseKinds = [{kind: "forgery"}]' 'row T1 caseKinds #1 has no case'
  expect_verify_refusal 't.rows[0].caseKinds = [{case: "posted id", kind: "tamper"}]' 'row T1 caseKinds #1 has illegal kind "tamper"'
}

@test "a keyed, retired or unflagged row needs no caseKinds" {
  write_forgery_table
  mutate_table '
    delete t.rows[0].caseKinds;
    t.rows[0].caseKey = "posted id";'
  verify
  [ "$status" -eq 0 ] || { echo "keyed: $output" >&2; return 1; }
  write_forgery_table
  mutate_table '
    delete t.rows[0].caseKinds;
    t.rows[0].action = "retire";'
  verify
  [ "$status" -eq 0 ] || { echo "retired: $output" >&2; return 1; }
  write_forgery_table
  mutate_table '
    delete t.rows[0].caseKinds;
    t.rows[0].security = "none";'
  verify
  [ "$status" -eq 0 ] || { echo "unflagged: $output" >&2; return 1; }
}

@test "amend refuses a mixed row and leaves the file unchanged" {
  write_forgery_table
  cp "$PLAN/tests.json" "$PLAN/tests.approved.json"
  local before
  before="$(cat "$PLAN/tests.json")"
  node -e '
    const row = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).rows[0];
    row.caseKinds.push({case: "remove own account: refused", kind: "access"});
    process.stdout.write(JSON.stringify({replace: [row]}));' "$PLAN/tests.json" >"$BATS_TEST_TMPDIR/changes.json"
  run node "$TABLE_CLI" amend --plan-dir "$PLAN" --root "$BATS_TEST_TMPDIR" --changes "$BATS_TEST_TMPDIR/changes.json"
  [ "$status" -eq 1 ]
  grep -qF 'row T1 holds cases of kinds forgery, access' <<<"$output" || { echo "$output" >&2; return 1; }
  [ "$(cat "$PLAN/tests.json")" = "$before" ]
}

@test "replanned-rows lists a row whose re-plan changed only its caseKinds" {
  write_forgery_table
  cp "$PLAN/tests.json" "$BATS_TEST_TMPDIR/before.json"
  mutate_table 't.rows[0].caseKinds[0].case = "own id posted for another account"'
  run node "$REPLANNED_CLI" --before "$BATS_TEST_TMPDIR/before.json" --after "$PLAN/tests.json"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$output" = 'T1 T1' ] || { echo "printed: $output" >&2; return 1; }
}
