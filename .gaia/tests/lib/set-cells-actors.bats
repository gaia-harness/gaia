#!/usr/bin/env bats
# verify's actor check of a rule over roles and statuses: the status entry's
# `actors` names the roles inside each action's set, each status cell names
# the role that acts, and every acting role must act at every status, so a
# status guard on one role's path alone fails the table.

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
  printf 'success_criteria:0\nsuccess_criteria:1\n' >"$KEYS"
  printf 'schema: 1\n' >"$PLAN/TEST-DESIGN"
  printf '# board\n\n- Test: src/board.test.ts \xe2\x80\xba board actions answer by role and status\n' >"$PLAN/task-board.md"
}

# Owner may view, edit and close; member may view and edit; guest may do
# nothing. Every action leaves from open; nothing is allowed on closed. The
# status rows spread the actors: member runs view and edit, owner runs close.
write_spread_table() {
  cat >"$PLAN/tests.json" <<'EOF'
{"schema": 1, "rows": [
  {"id": "T1", "source": "success_criteria:0", "case": "owner on an open board: view, edit, close each allowed", "file": "src/board.test.ts", "title": "board actions answer by role and status", "layer": "route", "task": "task-board", "action": "new", "security": "access", "caseKey": "owner",
   "cells": [{"action": "view", "role": "owner"}, {"action": "edit", "role": "owner"}, {"action": "close", "role": "owner"}]},
  {"id": "T2", "source": "success_criteria:0", "case": "member on an open board: view, edit allowed; close refused", "file": "src/board.test.ts", "title": "board actions answer by role and status", "layer": "route", "task": "task-board", "action": "new", "security": "access", "caseKey": "member",
   "cells": [{"action": "view", "role": "member"}, {"action": "edit", "role": "member"}, {"action": "close", "role": "member"}]},
  {"id": "T3", "source": "success_criteria:0", "case": "guest on an open board: view, edit, close each refused", "file": "src/board.test.ts", "title": "board actions answer by role and status", "layer": "route", "task": "task-board", "action": "new", "security": "access", "caseKey": "guest",
   "cells": [{"action": "view", "role": "guest"}, {"action": "edit", "role": "guest"}, {"action": "close", "role": "guest"}]},
  {"id": "T4", "source": "success_criteria:1", "case": "on an open board: member view, member edit, owner close each allowed", "file": "src/board.test.ts", "title": "board actions answer by role and status", "layer": "route", "task": "task-board", "action": "new", "security": "access", "caseKey": "open",
   "cells": [{"action": "view", "status": "open", "role": "member"}, {"action": "edit", "status": "open", "role": "member"}, {"action": "close", "status": "open", "role": "owner"}]},
  {"id": "T5", "source": "success_criteria:1", "case": "on a closed board: member view, member edit, owner close each refused", "file": "src/board.test.ts", "title": "board actions answer by role and status", "layer": "route", "task": "task-board", "action": "new", "security": "access", "caseKey": "closed",
   "cells": [{"action": "view", "status": "closed", "role": "member"}, {"action": "edit", "status": "closed", "role": "member"}, {"action": "close", "status": "closed", "role": "owner"}]}
],
"sets": [
  {"source": "success_criteria:0", "rows": ["T1", "T2", "T3"],
   "axes": {"action": ["view", "edit", "close"], "role": ["owner", "member", "guest"]}},
  {"source": "success_criteria:1", "rows": ["T4", "T5"],
   "axes": {"action": ["view", "edit", "close"], "status": ["open", "closed"]},
   "actors": {"role": {"view": ["owner", "member"], "edit": ["owner", "member"], "close": ["owner"]}}}
]}
EOF
}

mutate_table() {
  node "$MUTATE" "$PLAN/tests.json" "$1"
}

# Every status case run by the owner alone.
owner_only='for (const row of t.rows.slice(3)) {
  row.cells = row.cells.map((c) => ({...c, role: "owner"}));
  row.case = row.case.replaceAll("member", "owner");
}'

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

@test "verify passes a status table whose cases send every acting role past each status" {
  write_spread_table
  run_verify
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "verify refuses a status table run by the owner alone, naming each role missing at each status" {
  write_spread_table
  mutate_table "$owner_only"
  expect_refusal \
    'sets entry success_criteria:1 has no row for status open, role member' \
    'sets entry success_criteria:1 has no row for status closed, role member'
  [ "$(grep -c 'has no row for' <<<"$output")" -eq 2 ]
}

@test "verify refuses a status entry with no actors beside a role entry over the same actions" {
  write_spread_table
  mutate_table "$owner_only"' delete t.sets[1].actors;
    for (const row of t.rows.slice(3)) row.cells = row.cells.map(({action, status}) => ({action, status}));'
  expect_refusal 'sets entry success_criteria:1 pairs the actions with status while another entry pairs a shared action with role, but has no actors naming the role inside each action'"'"'s set'
}

@test "verify refuses a status entry with no actors when it gates only some of the role entry's actions" {
  write_spread_table
  mutate_table 'delete t.sets[1].actors; t.sets[1].axes.action = ["edit", "close"];
    for (const row of t.rows.slice(3)) row.cells = row.cells.filter((c) => c.action !== "view").map(({action, status}) => ({action, status}));
    for (const row of t.rows.slice(3)) row.case = row.case.replace("member view, ", "");'
  expect_refusal 'sets entry success_criteria:1 pairs the actions with status while another entry pairs a shared action with role, but has no actors naming the role inside each action'"'"'s set'
}

@test "verify passes a status entry with no actors when no entry pairs its actions with a role" {
  write_spread_table
  mutate_table 'delete t.sets[1].actors; t.sets.shift(); t.rows = t.rows.slice(3);
    for (const row of t.rows) row.cells = row.cells.map(({action, status}) => ({action, status}));'
  printf 'success_criteria:1\n' >"$KEYS"
  run_verify
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "verify refuses a status cell whose role is outside the action's set or that names no role" {
  write_spread_table
  mutate_table 't.rows[4].cells[2].role = "member"; t.rows[4].case += " member close"'
  expect_refusal 'row T5 cell #3 names role member, which sets entry success_criteria:1 actors does not list for action close'
  write_spread_table
  mutate_table 'delete t.rows[4].cells[0].role'
  expect_refusal 'row T5 cell #1 does not name exactly the axes and actor action, status, role of sets entry success_criteria:1'
}

@test "verify refuses malformed actors" {
  write_spread_table
  mutate_table 'delete t.sets[1].actors.role.close'
  expect_refusal 'sets entry success_criteria:1 actors role gives action close no non-empty list of members'
  write_spread_table
  mutate_table 't.sets[1].actors.role.view.push("visitor")'
  expect_refusal 'sets entry success_criteria:1 actors role names visitor for action view, which no entry'"'"'s role axis lists'
  write_spread_table
  mutate_table 't.sets[1].actors = {status: t.sets[1].actors.role}'
  expect_refusal 'sets entry success_criteria:1 actors names status, which is already one of its axes'
}
