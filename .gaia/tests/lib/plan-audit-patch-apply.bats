#!/usr/bin/env bats
# Flow test: a plan audit round whose lens fixes apply by script, with one
# replacement handed to a stand-in fix-up edit, every new or changed row listed
# for judgment, one row flagged, and the test table verifying. Fixtures use a
# community garden and a pottery studio.

# bats file_tags=installed-dependencies

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI="$REPO_ROOT/.gaia/scripts/test-design/plan-audit-apply.mjs"
  TABLE_CLI="$REPO_ROOT/.gaia/scripts/test-design/test-table.mjs"
  PLAN="$BATS_TEST_TMPDIR/plan"
  KEYS="$BATS_TEST_TMPDIR/keys.txt"
  DECISIONS="$BATS_TEST_TMPDIR/decisions.json"
  JUDGE="$BATS_TEST_TMPDIR/judge.json"
  mkdir -p "$PLAN/audit"
  printf '%s\n' flow:garden-booking success_criteria:0 success_criteria:1 >"$KEYS"

  cat >"$PLAN/tests.json" <<'JSON'
{
  "schema": 1,
  "rows": [
    {"id": "T1", "source": "flow:garden-booking", "case": "a member books a plot", "file": "plots.bats", "title": "plot booking succeeds", "layer": "shell", "task": "task-plots", "action": "new", "security": "none"},
    {"id": "T2", "source": "success_criteria:0", "case": "plots sort by size", "file": "plots.bats", "title": "plot list sorts by size", "layer": "shell", "task": "task-plots", "action": "new", "security": "none"},
    {"id": "T3", "source": "success_criteria:1", "case": "a class page lists its schedule", "file": "classes.bats", "title": "class page lists the schedule", "layer": "shell", "task": "task-classes", "action": "new", "security": "none"}
  ],
  "instructionKeys": []
}
JSON
  cat >"$PLAN/README.md" <<'MD'
# Plan

| Phase | Tasks |
| --- | --- |
| Phase 1 | `task-plots` |
| Phase 2 | `task-classes` |

## Test design

| id | source |
| --- | --- |
| T1 | stale |

## Follow-ups

- none
MD
  cat >"$PLAN/ORCHESTRATOR.md" <<'MD'
# Orchestrator

**Phase 1, Plots**

- Tasks (1): `task-plots`
- Gate suites: plots

**Phase 2, Classes**

- Tasks (1): `task-classes`
- Gate suites: classes
MD
  cat >"$PLAN/task-plots.md" <<'MD'
# task-plots

Book garden plots. Members book one plot per season.

- Test: plots.bats › plot booking succeeds
- Test: plots.bats › plot list sorts by size

Done when the suite passes.
MD
  cat >"$PLAN/task-classes.md" <<'MD'
# task-classes

Pottery class pages.

- Test: classes.bats › class page lists the schedule

Done when the suite passes.
MD
  cat >"$PLAN/audit/TD.json" <<'JSON'
{"dimension": "Test design", "findings": [
  {"id": "TD-001", "row_patches": [{"op": "add", "row": {"id": "T4", "source": "success_criteria:1", "case": "a pottery class page shows the cancel action only to its instructor", "file": "classes.bats", "title": "class page shows cancel only to the instructor", "layer": "shell", "task": "task-classes", "action": "new", "security": "none"}}]},
  {"id": "TD-002", "row_patches": [{"op": "change", "id": "T2", "set": {"title": "plot list sorts by area"}, "expect": {"title": "plot list sorts by size"}}]}
]}
JSON
  cat >"$PLAN/audit/DP.json" <<'JSON'
{"dimension": "Decomposition", "findings": [
  {"id": "DP-001", "replacements": [
    {"file": "task-plots.md", "old": "one plot per season", "new": "two plots per season"},
    {"file": "task-classes.md", "old": "Ceramics class pages.", "new": "Pottery and glazing class pages."}
  ]}
]}
JSON
  cat >"$DECISIONS" <<'JSON'
{"structural": false, "findings": [
  {"id": "TD-001", "decision": "apply"},
  {"id": "TD-002", "decision": "apply"},
  {"id": "DP-001", "decision": "apply"}
], "security_ruled_wrong": []}
JSON
}

# Prints one `<id>:<field>` value of tests.json, for example `T2:title`.
row_field() {
  node -e '
    const table = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const [id, field] = process.argv[2].split(":");
    const row = table.rows.find((candidate) => candidate.id === id);
    process.stdout.write(row ? String(row[field]) : "<absent>");
  ' "$PLAN/tests.json" "$1"
}

@test "plan audit fixes apply by script and every new or changed row is listed for judgment" {
  run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1

  run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "applied 2 fixup 1 review 0 replacements-script 1 replacements-fixup 1" ] || return 1

  [ "$(row_field T4:title)" = "class page shows cancel only to the instructor" ] || return 1
  [ "$(row_field T2:title)" = "plot list sorts by area" ] || return 1
  grep -qF 'two plots per season' "$PLAN/task-plots.md" || return 1
  grep -qF 'Test: classes.bats › class page shows cancel only to the instructor' "$PLAN/task-classes.md" || return 1
  grep -qF 'Ceramics class pages.' "$PLAN/audit/apply/fixup.json" || return 1

  # The stand-in for the fix-up agent applies the unmatched replacement by hand.
  sed -i.bak 's/^Pottery class pages\.$/Pottery and glazing class pages./' "$PLAN/task-classes.md"
  rm -f "$PLAN/task-classes.md.bak"
  grep -qF 'Pottery and glazing class pages.' "$PLAN/task-classes.md" || return 1

  run node "$CLI" judge-set --plan-dir "$PLAN" --out "$JUDGE"
  [ "$status" -eq 0 ] || return 1
  [ "$(node -e '
    const set = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write(set.map((entry) => entry.id + ":" + entry.change).sort().join(","));
  ' "$JUDGE")" = "T2:changed,T4:added" ] || return 1

  run node "$CLI" flag --plan-dir "$PLAN" --row T4 --kind access --cases '["a pottery class page shows the cancel action only to its instructor"]'
  [ "$status" -eq 0 ] || return 1
  [ "$(row_field T4:security)" = "access" ] || return 1
  grep -qF 'Security writer: 1 rows (T4)' "$PLAN/ORCHESTRATOR.md" || return 1

  run node "$TABLE_CLI" verify --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1
}
