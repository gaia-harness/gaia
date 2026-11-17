#!/usr/bin/env bats
# Plan audit apply CLI on a fix that writes a `sets` entry and its rows'
# cells: applied when the table's set cells still verify, held whole for the
# fix-up agent when they do not. Fixtures use a pottery studio.

# bats file_tags=installed-dependencies

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI="$REPO_ROOT/.gaia/scripts/test-design/plan-audit-apply.mjs"
  TABLE_CLI="$REPO_ROOT/.gaia/scripts/test-design/test-table.mjs"
  PLAN="$BATS_TEST_TMPDIR/plan"
  KEYS="$BATS_TEST_TMPDIR/keys.txt"
  DECISIONS="$BATS_TEST_TMPDIR/decisions.json"
  mkdir -p "$PLAN/audit"
  printf '%s\n' success_criteria:0 >"$KEYS"
  printf '%s\n' '{"structural": false, "findings": [{"id": "TD-001", "decision": "apply"}], "security_ruled_wrong": []}' >"$DECISIONS"

  cat >"$PLAN/tests.json" <<'JSON'
{
  "schema": 1,
  "rows": [
    {"id": "T1", "source": "success_criteria:0", "case": "a class page lists its schedule", "file": "classes.bats", "title": "class schedule", "layer": "shell", "task": "task-classes", "action": "new", "security": "none"},
    {"id": "T2", "source": "success_criteria:0", "case": "a class page shows cancel", "file": "classes.bats", "title": "class cancel", "layer": "shell", "task": "task-classes", "action": "new", "security": "none"}
  ]
}
JSON
  cat >"$PLAN/README.md" <<'MD'
# Plan

| Phase | Tasks |
| --- | --- |
| Phase 1 | `task-classes` |

## Test design

| id | source |
| --- | --- |
| T1 | stale |
MD
  cat >"$PLAN/ORCHESTRATOR.md" <<'MD'
# Orchestrator

**Phase 1, Classes**

- Tasks (1): `task-classes`
- Gate suites: classes
MD
  cat >"$PLAN/task-classes.md" <<'MD'
# task-classes

Pottery class pages.

- Test: classes.bats › class schedule
- Test: classes.bats › class cancel

Done when the suite passes.
MD
}

# Prints the table's sets entries and every row's cells as one JSON line.
sets_and_cells() {
  node -e '
    const table = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write(JSON.stringify({sets: table.sets ?? null, cells: table.rows.map((row) => row.cells ?? null)}));
  ' "$PLAN/tests.json"
}

@test "apply writes a sets entry and the cells of its rows from one finding" {
  cat >"$PLAN/audit/TD.json" <<'JSON'
{"dimension": "Test design", "findings": [
  {"id": "TD-001", "row_patches": [
    {"op": "sets", "entry": {"source": "success_criteria:0", "rows": ["T1", "T2"], "axes": {"action": ["list", "cancel"], "role": ["member", "guest"]}}, "expect": null},
    {"op": "change", "id": "T1", "set": {"case": "a member or a guest can list the schedule", "cells": [{"action": "list", "role": "member"}, {"action": "list", "role": "guest"}]}, "expect": {"case": "a class page lists its schedule", "cells": null}},
    {"op": "change", "id": "T2", "set": {"case": "a member or a guest can cancel", "cells": [{"action": "cancel", "role": "member"}, {"action": "cancel", "role": "guest"}]}, "expect": {"case": "a class page shows cancel", "cells": null}}
  ]}
]}
JSON
  run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
  run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "applied 3 fixup 0 review 0 replacements-script 0 replacements-fixup 0" ] || return 1
  [ "$(sets_and_cells)" = '{"sets":[{"source":"success_criteria:0","rows":["T1","T2"],"axes":{"action":["list","cancel"],"role":["member","guest"]}}],"cells":[[{"action":"list","role":"member"},{"action":"list","role":"guest"}],[{"action":"cancel","role":"member"},{"action":"cancel","role":"guest"}]]}' ] || return 1
  node "$TABLE_CLI" verify --plan-dir "$PLAN" --keys "$KEYS"
}

@test "apply writes a status entry's actors and the actor each cell names" {
  cat >"$PLAN/audit/TD.json" <<'JSON'
{"dimension": "Test design", "findings": [
  {"id": "TD-001", "row_patches": [
    {"op": "sets", "entry": {"source": "success_criteria:0", "rows": ["T2"], "axes": {"action": ["cancel"], "status": ["open", "full"]}, "actors": {"role": {"cancel": ["member"]}}}, "expect": null},
    {"op": "change", "id": "T2", "set": {"case": "a member can cancel an open or a full class", "cells": [{"action": "cancel", "status": "open", "role": "member"}, {"action": "cancel", "status": "full", "role": "member"}]}, "expect": {"case": "a class page shows cancel", "cells": null}}
  ]}
]}
JSON
  run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1
  run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "applied 2 fixup 0 review 0 replacements-script 0 replacements-fixup 0" ] || return 1
  [ "$(sets_and_cells)" = '{"sets":[{"source":"success_criteria:0","rows":["T2"],"axes":{"action":["cancel"],"status":["open","full"]},"actors":{"role":{"cancel":["member"]}}}],"cells":[null,[{"action":"cancel","status":"open","role":"member"},{"action":"cancel","status":"full","role":"member"}]]}' ] || return 1
  node "$TABLE_CLI" verify --plan-dir "$PLAN" --keys "$KEYS"
}

@test "a finding whose sets entry fails the set-cell check goes whole to fix-up, unapplied" {
  cat >"$PLAN/audit/TD.json" <<'JSON'
{"dimension": "Test design", "findings": [
  {"id": "TD-001", "row_patches": [
    {"op": "sets", "entry": {"source": "success_criteria:0", "rows": ["T2"], "axes": {"action": ["cancel"], "status": ["open", "full"]}, "actors": {"role": {"cancel": ["member"]}}}, "expect": null},
    {"op": "change", "id": "T2", "set": {"case": "a member can cancel an open class", "cells": [{"action": "cancel", "status": "open", "role": "member"}]}, "expect": {"case": "a class page shows cancel", "cells": null}}
  ]}
]}
JSON
  local before
  before="$(cksum <"$PLAN/tests.json")"
  run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "fixup TD-001 patch 0 set cells: sets entry success_criteria:0 has no row for action cancel, status full
fixup TD-001 patch 1 set cells: sets entry success_criteria:0 has no row for action cancel, status full" ] || return 1
  run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "applied 0 fixup 2 review 0 replacements-script 0 replacements-fixup 0" ] || return 1
  [ "$(cksum <"$PLAN/tests.json")" = "$before" ] || return 1
  node -e '
    const fixup = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const ops = fixup.map((entry) => `${entry.finding} ${entry.index} ${entry.item.op}`).join(",");
    if (ops !== "TD-001 0 sets,TD-001 1 change") process.exit(1);
    if (!fixup.every((entry) => entry.reason.startsWith("set cells: "))) process.exit(1);
  ' "$PLAN/audit/apply/fixup.json"
}
