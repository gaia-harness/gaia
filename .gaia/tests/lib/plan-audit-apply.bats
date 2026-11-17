#!/usr/bin/env bats
# Plan audit apply CLI: checks and applies lens row patches and replacements,
# lists added and changed rows for judgment, and keeps README, task docs and
# the phase plan in step. Fixtures use a community garden and a pottery studio.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI="$REPO_ROOT/.gaia/scripts/test-design/plan-audit-apply.mjs"
  TABLE_CLI="$REPO_ROOT/.gaia/scripts/test-design/test-table.mjs"
  PLAN="$BATS_TEST_TMPDIR/plan"
  KEYS="$BATS_TEST_TMPDIR/keys.txt"
  DECISIONS="$BATS_TEST_TMPDIR/decisions.json"
  mkdir -p "$PLAN/audit"
  printf '%s\n' flow:garden-booking success_criteria:0 success_criteria:1 success_criteria:2 scope_boundaries:never:0 >"$KEYS"

  cat >"$PLAN/tests.json" <<'JSON'
{
  "schema": 1,
  "rows": [
    {"id": "T1", "source": "flow:garden-booking", "case": "a member books a plot", "file": "plots.bats", "title": "plot booking succeeds", "layer": "shell", "task": "task-plots", "action": "new", "security": "none"},
    {"id": "T2", "source": "success_criteria:0", "case": "a non-member booking is refused", "file": "plots.bats", "title": "non-member booking is refused", "layer": "shell", "task": "task-plots", "action": "new", "security": "access"},
    {"id": "T3", "source": "success_criteria:1", "case": "plots sort by size", "file": "plots.bats", "title": "plot list sorts by size", "layer": "shell", "task": "task-plots", "action": "new", "security": "none"},
    {"id": "T4", "source": "success_criteria:2", "case": "a class page lists its schedule", "file": "classes.bats", "title": "class page lists the schedule", "layer": "shell", "task": "task-classes", "action": "new", "security": "none"},
    {"id": "T5", "source": "success_criteria:2", "case": "a class page shows cancel", "file": "classes.bats", "title": "class page shows the cancel action", "layer": "shell", "task": "task-classes", "action": "new", "security": "none"}
  ],
  "instructionKeys": [{"source": "scope_boundaries:never:0", "reason": "keep the garden rules unchanged"}]
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

- `scope_boundaries:never:0`: stale reason

## Follow-ups

- none
MD
  cat >"$PLAN/ORCHESTRATOR.md" <<'MD'
# Orchestrator

**Phase 1, Plots**

- Tasks (1): `task-plots`
- Security writer: 1 rows (T2)
- Gate suites: plots

**Phase 2, Classes**

- Tasks (1): `task-classes`
- Gate suites: classes
MD
  cat >"$PLAN/task-plots.md" <<'MD'
# task-plots

Book garden plots.

- Test: plots.bats › plot booking succeeds
- Test: plots.bats › non-member booking is refused
- Test: plots.bats › plot list sorts by size

Done when the suite passes.
MD
  cat >"$PLAN/task-classes.md" <<'MD'
# task-classes

Pottery class pages.

- Test: classes.bats › class page lists the schedule
- Test: classes.bats › class page shows the cancel action

Done when the suite passes.
MD
}

# Prints a checksum line per plan document outside the apply working folder.
plan_sums() {
  (cd "$PLAN" && for name in tests.json README.md ORCHESTRATOR.md task-*.md; do cksum "$name"; done)
}

# Prints one `<id>:<field>` value of tests.json, for example `T3:title`.
row_field() {
  node -e '
    const table = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const [id, field] = process.argv[2].split(":");
    const row = table.rows.find((candidate) => candidate.id === id);
    process.stdout.write(row ? String(row[field]) : "<absent>");
  ' "$PLAN/tests.json" "$1"
}

@test "apply applies only accepted fixes that pass and keeps sole rows" {
  cat >"$PLAN/audit/TD.json" <<'JSON'
{"dimension": "Test design", "findings": [
  {"id": "TD-001", "row_patches": [{"op": "change", "id": "T3", "set": {"title": "plot list sorts by area"}, "expect": {"title": "plot list sorts by size"}}]},
  {"id": "TD-002", "row_patches": [{"op": "change", "id": "T1", "set": {"case": "a member books any plot"}, "expect": {"case": "a member books a plot"}}]},
  {"id": "TD-003", "row_patches": [{"op": "change", "id": "T1", "set": {"layer": "unit"}, "expect": {"layer": "shell"}}]},
  {"id": "TD-004", "row_patches": [{"op": "add", "row": {"id": "T9", "source": "bogus:key", "case": "x", "file": "plots.bats", "title": "bogus", "layer": "shell", "task": "task-plots", "action": "new", "security": "none"}}]},
  {"id": "TD-005", "row_patches": [{"op": "add", "row": {"id": "T3", "source": "success_criteria:1", "case": "x", "file": "plots.bats", "title": "duplicate id", "layer": "shell", "task": "task-plots", "action": "new", "security": "none"}}]},
  {"id": "TD-006", "row_patches": [{"op": "change", "id": "T3", "set": {"source": "success_criteria:0"}, "expect": {"source": "success_criteria:1"}}]},
  {"id": "TD-007", "row_patches": [{"op": "remove", "id": "T4", "expect": {"file": "classes.bats", "title": "class page lists the schedule", "security": "none"}}]},
  {"id": "TD-008", "row_patches": [{"op": "remove", "id": "T5", "expect": {"file": "classes.bats", "title": "class page shows the cancel action", "security": "none"}}]},
  {"id": "TD-009", "row_patches": [{"op": "add", "row": {"id": "T6", "source": "success_criteria:0", "case": "a lapsed member booking is refused", "file": "classes.bats", "title": "lapsed booking is refused", "layer": "shell", "task": "task-classes", "action": "new", "security": "none"}}]}
]}
JSON
  cat >"$DECISIONS" <<'JSON'
{"structural": false, "findings": [
  {"id": "TD-001", "decision": "apply"},
  {"id": "TD-002", "decision": "drop"},
  {"id": "TD-003", "decision": "revise", "revision": "keep the layer, reword the case"},
  {"id": "TD-004", "decision": "apply"},
  {"id": "TD-005", "decision": "apply"},
  {"id": "TD-006", "decision": "apply"},
  {"id": "TD-007", "decision": "apply"},
  {"id": "TD-008", "decision": "apply"},
  {"id": "TD-009", "decision": "apply"}
], "security_ruled_wrong": []}
JSON
  run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1
  grep -qF 'review TD-008 patch 0' <<<"$output" || return 1
  run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "applied 3 fixup 1 review 4 replacements-script 0 replacements-fixup 0" ] || return 1

  [ "$(row_field T3:title)" = "plot list sorts by area" ] || return 1
  [ "$(row_field T1:case)" = "a member books a plot" ] || return 1
  [ "$(row_field T1:layer)" = "shell" ] || return 1
  [ "$(row_field T4:id)" = "<absent>" ] || return 1
  [ "$(row_field T5:id)" = "T5" ] || return 1
  [ "$(row_field T6:title)" = "lapsed booking is refused" ] || return 1
  [ "$(row_field T9:id)" = "<absent>" ] || return 1

  node -e '
    const read = (name) => JSON.parse(require("fs").readFileSync(process.argv[1] + "/audit/apply/" + name, "utf8"));
    const fixup = read("fixup.json");
    const review = read("review.json").map((entry) => entry.finding).sort().join(",");
    if (fixup.length !== 1 || fixup[0].finding !== "TD-003" || fixup[0].kind !== "revision") process.exit(1);
    if (fixup[0].item.revision !== "keep the layer, reword the case") process.exit(1);
    if (review !== "TD-004,TD-005,TD-006,TD-008") process.exit(1);
  ' "$PLAN" || return 1

  grep -qF '| T3 | success_criteria:1 | plots sort by size | plots.bats | plot list sorts by area | shell | task-plots | new | none |' "$PLAN/README.md" || return 1
  grep -qF '| T6 | success_criteria:0 | a lapsed member booking is refused | classes.bats | lapsed booking is refused | shell | task-classes | new | none |' "$PLAN/README.md" || return 1
  grep -qF '| T4 |' "$PLAN/README.md" && return 1
  # shellcheck disable=SC2016
  grep -qF -- '- `scope_boundaries:never:0`: keep the garden rules unchanged' "$PLAN/README.md" || return 1
  grep -qF -- '- Test: plots.bats › plot list sorts by area' "$PLAN/task-plots.md" || return 1
  grep -qF 'sorts by size' "$PLAN/task-plots.md" && return 1
  grep -qF 'lists the schedule' "$PLAN/task-classes.md" && return 1
  grep -qF -- '- Test: classes.bats › class page shows the cancel action' "$PLAN/task-classes.md" || return 1
  [ "$(grep -n -- '- Test: classes.bats › lapsed booking is refused' "$PLAN/task-classes.md" | cut -d: -f1)" = "6" ] || return 1
  grep -qF '## Follow-ups' "$PLAN/README.md" || return 1
  node "$TABLE_CLI" verify --plan-dir "$PLAN" --keys "$KEYS"
}

@test "apply changes nothing in a round with a surviving structural finding" {
  cat >"$PLAN/audit/DP.json" <<'JSON'
{"dimension": "Decomposition", "findings": [
  {"id": "DP-001", "row_patches": [{"op": "change", "id": "T3", "set": {"title": "plot list sorts by area"}, "expect": {"title": "plot list sorts by size"}}]}
]}
JSON
  printf '%s\n' '{"structural": true, "findings": [{"id": "DP-001", "decision": "apply"}], "security_ruled_wrong": []}' >"$DECISIONS"
  run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1
  plan_sums >"$BATS_TEST_TMPDIR/before.sums"
  run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
  [ "$status" -eq 3 ] || return 1
  plan_sums >"$BATS_TEST_TMPDIR/after.sums"
  cmp -s "$BATS_TEST_TMPDIR/before.sums" "$BATS_TEST_TMPDIR/after.sums" || return 1
  [ -e "$PLAN/audit/apply/applied.json" ] && return 1
  true
}

@test "a rerun applies no finding twice and keeps the first snapshot" {
  cat >"$PLAN/audit/TD.json" <<'JSON'
{"dimension": "Test design", "findings": [
  {"id": "TD-001", "row_patches": [{"op": "change", "id": "T3", "set": {"title": "plot list sorts by area"}, "expect": {"title": "plot list sorts by size"}}]},
  {"id": "TD-002", "row_patches": [{"op": "change", "id": "T1", "set": {"title": "plot booking is confirmed"}, "expect": {"title": "plot booking succeeds"}}]}
]}
JSON
  printf '%s\n' '{"structural": false, "findings": [{"id": "TD-001", "decision": "apply"}, {"id": "TD-002", "decision": "apply"}], "security_ruled_wrong": []}' >"$DECISIONS"
  run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1
  cp -R "$PLAN" "$BATS_TEST_TMPDIR/pristine"
  run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
  [ "$status" -eq 0 ] || return 1
  plan_sums >"$BATS_TEST_TMPDIR/first.sums"

  run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "applied 0 fixup 0 review 0 replacements-script 0 replacements-fixup 0" ] || return 1
  plan_sums >"$BATS_TEST_TMPDIR/second.sums"
  cmp -s "$BATS_TEST_TMPDIR/first.sums" "$BATS_TEST_TMPDIR/second.sums" || return 1
  run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1
  grep -qF 'plot list sorts by size' "$PLAN/audit/apply/snapshot/tests.json" || return 1

  rm -rf "$PLAN"
  cp -R "$BATS_TEST_TMPDIR/pristine" "$PLAN"
  printf '%s\n' '["TD-001"]' >"$PLAN/audit/apply/applied.json"
  run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
  [ "$status" -eq 0 ] || return 1
  [ "$(row_field T3:title)" = "plot list sorts by size" ] || return 1
  [ "$(row_field T1:title)" = "plot booking is confirmed" ] || return 1
  grep -qF '"TD-002"' "$PLAN/audit/apply/applied.json"
}

@test "a row patch applies only when its expected prior values still hold" {
  cat >"$PLAN/audit/TD.json" <<'JSON'
{"dimension": "Test design", "findings": [
  {"id": "TD-001", "row_patches": [{"op": "change", "id": "T3", "set": {"title": "plot list sorts by area"}, "expect": {"title": "plot list sorts by size"}}]},
  {"id": "TD-002", "row_patches": [{"op": "change", "id": "T1", "set": {"case": "a member books any plot"}, "expect": {"case": "a member books a plot"}}]},
  {"id": "TD-003", "row_patches": [{"op": "change", "id": "T4", "set": {"title": "class page lists times"}, "expect": {"title": "class page lists the schedule"}}]},
  {"id": "TD-004", "row_patches": [{"op": "change", "id": "T4", "set": {"title": "class page lists dates"}, "expect": {"title": "class page lists the schedule"}}]}
]}
JSON
  printf '%s\n' '{"structural": false, "findings": [{"id": "TD-001", "decision": "apply"}, {"id": "TD-002", "decision": "apply"}, {"id": "TD-003", "decision": "apply"}, {"id": "TD-004", "decision": "apply"}], "security_ruled_wrong": []}' >"$DECISIONS"
  run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1
  grep -qF 'review TD-003 patch 0' <<<"$output" || return 1
  grep -qF 'review TD-004 patch 0' <<<"$output" || return 1
  grep -qF 'TD-002' <<<"$output" && return 1
  # The prior value of T1's case moves between prepare and apply.
  sed -i.bak 's/a member books a plot/a member reserves a plot/' "$PLAN/tests.json"
  run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "applied 1 fixup 0 review 3 replacements-script 0 replacements-fixup 0" ] || return 1
  [ "$(row_field T3:title)" = "plot list sorts by area" ] || return 1
  [ "$(row_field T1:case)" = "a member reserves a plot" ] || return 1
  [ "$(row_field T4:title)" = "class page lists the schedule" ] || return 1
  node -e '
    const review = JSON.parse(require("fs").readFileSync(process.argv[1] + "/audit/apply/review.json", "utf8"));
    if (review.map((entry) => entry.finding).sort().join(",") !== "TD-002,TD-003,TD-004") process.exit(1);
  ' "$PLAN"
}

@test "judge set lists every added, changed and unflagged row against the snapshot" {
  run node "$CLI" judge-set --plan-dir "$PLAN" --out "$BATS_TEST_TMPDIR/judge.json"
  [ "$status" -eq 1 ] || return 1
  run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1
  node -e '
    const fs = require("fs");
    const file = process.argv[1] + "/tests.json";
    const table = JSON.parse(fs.readFileSync(file, "utf8"));
    const base = {layer: "shell", action: "new", security: "none", file: "garden.bats"};
    table.rows.find((row) => row.id === "T2").security = "none";
    table.rows.find((row) => row.id === "T3").title = "plot list sorts by area";
    table.rows.push(
      {...base, id: "T6", source: "success_criteria:0", case: "a community garden plot booking is refused for a non-member", title: "non-member plot booking is refused", task: "task-plots"},
      {...base, id: "T7", source: "success_criteria:2", case: "a pottery class page shows the cancel action only to its instructor", title: "cancel action shows to the instructor only", task: "task-classes"},
      {...base, id: "T8", source: "success_criteria:1", case: "a recipe app sign-in return target off-site is refused", title: "off-site return target is refused", task: "task-plots"},
    );
    fs.writeFileSync(file, JSON.stringify(table, null, 2) + "\n");
  ' "$PLAN"
  run node "$CLI" judge-set --plan-dir "$PLAN" --out "$BATS_TEST_TMPDIR/judge.json"
  [ "$status" -eq 0 ] || return 1
  result="$(node -e '
    const set = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write(set.map((entry) => entry.id + ":" + entry.change).join(" "));
  ' "$BATS_TEST_TMPDIR/judge.json")"
  [ "$result" = "T2:unflagged T3:changed T6:added T7:added T8:added" ]
}

@test "flag sets a judged kind on the row, its README row and its phase Security writer line" {
  run node "$CLI" flag --plan-dir "$PLAN" --row T4 --kind access
  [ "$status" -eq 0 ] || return 1
  [ "$(row_field T4:security)" = "access" ] || return 1
  grep -qF '| T4 | success_criteria:2 | a class page lists its schedule | classes.bats | class page lists the schedule | shell | task-classes | new | access |' "$PLAN/README.md" || return 1
  grep -qF -- '- Security writer: 1 rows (T4)' "$PLAN/ORCHESTRATOR.md" || return 1
  [ "$(grep -n 'Security writer' "$PLAN/ORCHESTRATOR.md" | tail -1 | cut -d: -f1)" = "12" ] || return 1

  run node "$CLI" flag --plan-dir "$PLAN" --row T3 --kind secret
  [ "$status" -eq 0 ] || return 1
  grep -qF -- '- Security writer: 2 rows (T2, T3)' "$PLAN/ORCHESTRATOR.md" || return 1
  grep -qF -- '- Security writer: 1 rows (T4)' "$PLAN/ORCHESTRATOR.md" || return 1
  [ "$(row_field T3:security)" = "secret" ] || return 1
  run node "$CLI" flag --plan-dir "$PLAN" --row T9 --kind access
  [ "$status" -eq 1 ] || return 1
  node "$TABLE_CLI" verify --plan-dir "$PLAN" --keys "$KEYS"
}

@test "a malformed row patch goes to the fix-up list" {
  cat >"$PLAN/audit/TD.json" <<'JSON'
{"dimension": "Test design", "findings": [
  {"id": "TD-001", "row_patches": [
    {"id": "T3", "set": {"title": "x"}},
    {"op": "mutate", "id": "T3"},
    {"op": "change", "id": "T3", "set": {"title": "x"}},
    {"op": "change", "id": "T3", "set": {"title": "x", "case": "y"}, "expect": {"title": "plot list sorts by size"}}
  ]},
  {"id": "TD-002"},
  {"id": "TD-003", "row_patches": [{"op": "change", "id": "T1", "set": {"case": "a member books any plot"}, "expect": {"case": "a member books a plot"}}]}
]}
JSON
  printf '%s\n' '{"structural": false, "findings": [{"id": "TD-001", "decision": "apply"}, {"id": "TD-002", "decision": "apply"}, {"id": "TD-003", "decision": "apply"}], "security_ruled_wrong": []}' >"$DECISIONS"
  run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || return 1
  run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "applied 1 fixup 5 review 0 replacements-script 0 replacements-fixup 0" ] || return 1
  [ "$(row_field T3:title)" = "plot list sorts by size" ] || return 1
  [ "$(row_field T1:case)" = "a member books any plot" ] || return 1
  node -e '
    const fixup = JSON.parse(require("fs").readFileSync(process.argv[1] + "/audit/apply/fixup.json", "utf8"));
    const summary = fixup.map((entry) => entry.finding + ":" + entry.kind + ":" + entry.index).join(" ");
    if (summary !== "TD-001:patch:0 TD-001:patch:1 TD-001:patch:2 TD-001:patch:3 TD-002:patch:0") process.exit(1);
    if (fixup[0].item.set.title !== "x" || fixup[0].item.op !== undefined) process.exit(1);
    if (fixup[4].reason !== "no fix to apply") process.exit(1);
  ' "$PLAN"
}

@test "apply refuses a patch that removes or weakens a flagged row unless the review list ruled it wrong" {
  run node "$CLI" flag --plan-dir "$PLAN" --row T4 --kind access
  [ "$status" -eq 0 ] || return 1
  cp -R "$PLAN" "$BATS_TEST_TMPDIR/flagged"
  local patches=(
    '{"op": "remove", "id": "T4", "expect": {"file": "classes.bats", "title": "class page lists the schedule", "security": "access"}}'
    '{"op": "change", "id": "T4", "set": {"security": "none"}, "expect": {"security": "access"}}'
    '{"op": "change", "id": "T4", "set": {"security": "forgery"}, "expect": {"security": "access"}}'
    '{"op": "change", "id": "T4", "set": {"action": "retire"}, "expect": {"action": "new"}}'
  )
  local patch
  for patch in "${patches[@]}"; do
    rm -rf "$PLAN"
    cp -R "$BATS_TEST_TMPDIR/flagged" "$PLAN"
    printf '{"dimension": "Test design", "findings": [{"id": "TD-001", "row_patches": [%s]}]}\n' "$patch" >"$PLAN/audit/TD.json"

    # Not ruled wrong: nothing applied, the finding is listed for review, the row is unchanged.
    printf '%s\n' '{"structural": false, "findings": [{"id": "TD-001", "decision": "apply"}], "security_ruled_wrong": []}' >"$DECISIONS"
    run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
    [ "$status" -eq 0 ] || return 1
    run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
    [ "$status" -eq 0 ] || return 1
    [ "$output" = "applied 0 fixup 0 review 1 replacements-script 0 replacements-fixup 0" ] || return 1
    [ "$(row_field T4:id)" = "T4" ] || return 1
    [ "$(row_field T4:security)" = "access" ] || return 1
    [ "$(row_field T4:action)" = "new" ] || return 1
    node -e '
      const review = JSON.parse(require("fs").readFileSync(process.argv[1] + "/audit/apply/review.json", "utf8"));
      if (review.length !== 1 || review[0].finding !== "TD-001") process.exit(1);
    ' "$PLAN" || return 1

    # Ruled wrong in the decisions file: the same patch is applied.
    rm -rf "$PLAN"
    cp -R "$BATS_TEST_TMPDIR/flagged" "$PLAN"
    printf '{"dimension": "Test design", "findings": [{"id": "TD-001", "row_patches": [%s]}]}\n' "$patch" >"$PLAN/audit/TD.json"
    printf '%s\n' '{"structural": false, "findings": [{"id": "TD-001", "decision": "apply"}], "security_ruled_wrong": ["T4"]}' >"$DECISIONS"
    run node "$CLI" prepare --plan-dir "$PLAN" --keys "$KEYS"
    [ "$status" -eq 0 ] || return 1
    run node "$CLI" apply --plan-dir "$PLAN" --keys "$KEYS" --decisions "$DECISIONS"
    [ "$status" -eq 0 ] || return 1
    [ "$output" = "applied 1 fixup 0 review 0 replacements-script 0 replacements-fixup 0" ] || return 1
  done
}
