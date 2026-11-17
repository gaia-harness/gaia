#!/usr/bin/env bats
# verify's cell check of a set-stated rule's case table: every combination of
# a `sets` entry's axes needs a row cell, and each cell names members its
# entry lists and its row's case names.

# bats file_tags=installed-dependencies

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TABLE_CLI="$REPO_ROOT/.gaia/scripts/test-design/test-table.mjs"
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
  printf '# admin\n\n- Test: src/admin.test.ts \xe2\x80\xba admin actions answer by role\n' >"$PLAN/task-admin.md"
}

# An admin-only rule over three actions and four roles: one row per role,
# sharing one case table, each naming its role's three cells.
write_full_table() {
  cat >"$PLAN/tests.json" <<'EOF'
{"schema": 1, "rows": [
  {"id": "T1", "source": "success_criteria:0", "case": "admin: list, view, create each allowed", "file": "src/admin.test.ts", "title": "admin actions answer by role", "layer": "route", "task": "task-admin", "action": "new", "security": "access", "caseKey": "admin",
   "cells": [{"action": "list", "role": "admin"}, {"action": "view", "role": "admin"}, {"action": "create", "role": "admin"}]},
  {"id": "T2", "source": "success_criteria:0", "case": "editor: list, view, create each refused", "file": "src/admin.test.ts", "title": "admin actions answer by role", "layer": "route", "task": "task-admin", "action": "new", "security": "access", "caseKey": "editor",
   "cells": [{"action": "list", "role": "editor"}, {"action": "view", "role": "editor"}, {"action": "create", "role": "editor"}]},
  {"id": "T3", "source": "success_criteria:0", "case": "viewer: list, view, create each refused", "file": "src/admin.test.ts", "title": "admin actions answer by role", "layer": "route", "task": "task-admin", "action": "new", "security": "access", "caseKey": "viewer",
   "cells": [{"action": "list", "role": "viewer"}, {"action": "view", "role": "viewer"}, {"action": "create", "role": "viewer"}]},
  {"id": "T4", "source": "success_criteria:0", "case": "guest: list, view, create each refused", "file": "src/admin.test.ts", "title": "admin actions answer by role", "layer": "route", "task": "task-admin", "action": "new", "security": "access", "caseKey": "guest",
   "cells": [{"action": "list", "role": "guest"}, {"action": "view", "role": "guest"}, {"action": "create", "role": "guest"}]}
],
"sets": [{"source": "success_criteria:0", "rows": ["T1", "T2", "T3", "T4"],
  "axes": {"action": ["list", "view", "create"], "role": ["admin", "editor", "viewer", "guest"]}}]}
EOF
}

# The same rule sampled: each action refuses one non-admin, so every role
# appears somewhere but six refusal cells have no row.
write_sampled_table() {
  write_full_table
  mutate_table '
    t.rows = [t.rows[0],
      {...t.rows[1], id: "T2", caseKey: "sampled", case: "viewer list, editor view, guest create: each refused",
       cells: [{action: "list", role: "viewer"}, {action: "view", role: "editor"}, {action: "create", role: "guest"}]}];
    t.sets[0].rows = ["T1", "T2"];'
}

mutate_table() {
  node "$MUTATE" "$PLAN/tests.json" "$1"
}

run_verify() {
  run node "$TABLE_CLI" verify --plan-dir "$PLAN" --keys "$KEYS"
}

expect_refusal() {
  run_verify
  if [ "$status" -ne 1 ]; then
    echo "expected exit 1, got $status: $output" >&2
    return 1
  fi
  local needle
  for needle in "$@"; do
    grep -qF -- "$needle" <<<"$output" || {
      echo "stderr lacks '$needle': $output" >&2
      return 1
    }
  done
}

@test "verify passes a set-stated table holding every cell of its axes" {
  write_full_table
  run_verify
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "verify refuses a sampled table, naming each combination with no row" {
  write_sampled_table
  expect_refusal \
    'sets entry success_criteria:0 has no row for action list, role editor' \
    'sets entry success_criteria:0 has no row for action list, role guest' \
    'sets entry success_criteria:0 has no row for action view, role viewer' \
    'sets entry success_criteria:0 has no row for action view, role guest' \
    'sets entry success_criteria:0 has no row for action create, role editor' \
    'sets entry success_criteria:0 has no row for action create, role viewer'
  [ "$(grep -c 'has no row for' <<<"$output")" -eq 6 ]
}

@test "the sampled table passes verify without its sets entry" {
  write_sampled_table
  mutate_table 'delete t.sets'
  run_verify
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "verify refuses a cell whose member the row's case does not name" {
  write_full_table
  mutate_table 't.rows[3].case = "anonymous: list, view, create each refused"'
  expect_refusal 'row T4 cell #1 names role guest, which the row'"'"'s case does not'
}

@test "verify refuses a cell naming a member its entry does not list or missing one of its axes" {
  write_full_table
  mutate_table 't.rows[3].cells[0].role = "owner"; t.rows[3].case += " owner"'
  expect_refusal 'row T4 cell #1 names role owner, which sets entry success_criteria:0 does not list'
  write_full_table
  mutate_table 't.rows[3].cells[0] = {action: "list"}'
  expect_refusal 'row T4 cell #1 does not name exactly the axes action, role of sets entry success_criteria:0'
}

@test "verify refuses a malformed sets entry" {
  write_full_table
  mutate_table 't.sets[0].source = "flow:stray"'
  expect_refusal 'sets entry flow:stray cites unknown source flow:stray'
  write_full_table
  mutate_table 'delete t.sets[0].axes.role'
  expect_refusal 'sets entry success_criteria:0 names fewer than two axes'
  write_full_table
  mutate_table 't.sets[0].axes.role.push("admin")'
  expect_refusal 'sets entry success_criteria:0 axis role lists a member twice'
  write_full_table
  mutate_table 't.sets[0].rows.push("T9")'
  expect_refusal 'sets entry success_criteria:0 names row T9, which the table lacks'
  write_full_table
  mutate_table 'delete t.rows[3].cells'
  expect_refusal 'sets entry success_criteria:0 lists row T4, which has no cells'
  write_full_table
  mutate_table 't.sets = {}'
  expect_refusal 'sets is not an array'
}

@test "verify accepts a cell written in a different key order than the axes" {
  write_full_table
  mutate_table 't.rows[0].cells = t.rows[0].cells.map((c) => ({role: c.role, action: c.action}))'
  run_verify
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "verify refuses a cell whose member the case names only inside a longer word" {
  write_full_table
  mutate_table 't.rows[0].case = "admin: list, viewer, create each allowed"'
  expect_refusal 'row T1 cell #2 names action view, which the row'"'"'s case does not'
}

@test "amend refuses a removal that leaves a sets entry uncovered and leaves the file unchanged" {
  write_full_table
  cp "$PLAN/tests.json" "$PLAN/tests.approved.json"
  before="$(cat "$PLAN/tests.json")"
  printf '%s' '{"remove":["T4"]}' >"$BATS_TEST_TMPDIR/changes.json"
  run node "$TABLE_CLI" amend --plan-dir "$PLAN" --root "$BATS_TEST_TMPDIR" --changes "$BATS_TEST_TMPDIR/changes.json"
  [ "$status" -eq 1 ]
  grep -qF -- 'names row T4, which the table lacks' <<<"$output"
  [ "$(cat "$PLAN/tests.json")" = "$before" ]
}
