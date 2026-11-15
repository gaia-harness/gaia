#!/usr/bin/env bats
#
# A Structural re-plan in the decomposition audit regenerates tests.json, so a
# security row it drops, unflags or moves to another kind must still reach the
# review list. This suite runs security-rows-lost.mjs, the compare the apply
# step calls, against fixture tables, and pins the apply step's text that
# snapshots the table, runs the compare and holds each lost row.
#
# Method: behavior cases build a before and an after table; red twins mutate
# one substring of a scratch copy (the compare's match key, or the apply
# step's text), prove the copy changed, and rerun the same check against it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS_REL=".gaia/scripts/test-design"
  AUDIT_REL=".claude/skills/gaia/references/plan/decomposition-audit.md"
  BEFORE="$BATS_TEST_TMPDIR/before.json"
  AFTER="$BATS_TEST_TMPDIR/after.json"
  write_table "$BEFORE" \
    '{"id": "T1", "source": "success_criteria:0", "security": "access"}' \
    '{"id": "T2", "source": "success_criteria:1", "security": "forgery"}' \
    '{"id": "T3", "source": "flow:alpha", "security": "none"}'
}

# write_table <file> <row>...: a table whose rows carry only the fields the
# compare reads.
write_table() {
  local file="$1" rows
  shift
  rows="$(IFS=,; printf '%s' "$*")"
  printf '{"schema": 1, "rows": [%s]}\n' "$rows" > "$file"
}

# compare <root>: run the compare from <root> over BEFORE and AFTER.
compare() {
  run node "$1/$SCRIPTS_REL/security-rows-lost.mjs" --before "$BEFORE" --after "$AFTER"
}

@test "an unchanged security set reports nothing" {
  cp "$BEFORE" "$AFTER"
  compare "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a renumbered security row with the same source and kind is not lost" {
  write_table "$AFTER" \
    '{"id": "T7", "source": "success_criteria:0", "security": "access"}' \
    '{"id": "T8", "source": "success_criteria:1", "security": "forgery"}'
  compare "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a dropped security row is lost" {
  write_table "$AFTER" \
    '{"id": "T2", "source": "success_criteria:1", "security": "forgery"}'
  compare "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 'lost: access success_criteria:0 (1 of T1)' ]
}

@test "a security row set to none is lost" {
  write_table "$AFTER" \
    '{"id": "T1", "source": "success_criteria:0", "security": "none"}' \
    '{"id": "T2", "source": "success_criteria:1", "security": "forgery"}'
  compare "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 'lost: access success_criteria:0 (1 of T1)' ]
}

@test "a security row moved to another kind is lost" {
  write_table "$AFTER" \
    '{"id": "T1", "source": "success_criteria:0", "security": "secret"}' \
    '{"id": "T2", "source": "success_criteria:1", "security": "forgery"}'
  compare "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 'lost: access success_criteria:0 (1 of T1)' ]
}

@test "a dropped row whose id another row of the same kind reuses is lost" {
  write_table "$AFTER" \
    '{"id": "T1", "source": "success_criteria:9", "security": "access"}' \
    '{"id": "T2", "source": "success_criteria:1", "security": "forgery"}'
  compare "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 'lost: access success_criteria:0 (1 of T1)' ]
}

@test "one of two rows sharing a source and kind dropped is lost" {
  write_table "$BEFORE" \
    '{"id": "T1", "source": "success_criteria:0", "security": "access"}' \
    '{"id": "T4", "source": "success_criteria:0", "security": "access"}'
  write_table "$AFTER" \
    '{"id": "T1", "source": "success_criteria:0", "security": "access"}'
  compare "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 'lost: access success_criteria:0 (1 of T1, T4)' ]
}

@test "an unreadable table exits 1 with a reason, never an empty report" {
  printf 'not json\n' > "$AFTER"
  compare "$REPO_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *'security-rows-lost: '*'is not valid JSON'* ]]
}

@test "a missing flag exits 2 with usage" {
  run node "$REPO_ROOT/$SCRIPTS_REL/security-rows-lost.mjs" --before "$BEFORE"
  [ "$status" -eq 2 ]
  [[ "$output" == 'usage: '* ]]
}

# mutated_tree <relpath> <old> <new>: copy the compare, its table reader and the
# decomposition audit into a scratch tree (TREE), replace the first fixed-string
# <old> in <relpath> with <new>, and prove the copy changed.
mutated_tree() {
  local rel="$1" old="$2" new="$3" file content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for file in "$SCRIPTS_REL/security-rows-lost.mjs" "$SCRIPTS_REL/table.mjs" "$AUDIT_REL"; do
    mkdir -p "$TREE/$(dirname "$file")"
    cp "$REPO_ROOT/$file" "$TREE/$file"
  done
  content="$(cat "$TREE/$rel"; printf x)"
  mutated="${content/"$old"/"$new"}"
  printf '%s' "${mutated%x}" > "$TREE/$rel"
  if cmp -s "$REPO_ROOT/$rel" "$TREE/$rel"; then
    printf 'mutation left %s unchanged: %s\n' "$rel" "$old" >&2
    return 1
  fi
}

@test "red twin: matching security rows by id misses a dropped row whose id is reused" {
  mutated_tree "$SCRIPTS_REL/security-rows-lost.mjs" 'JSON.stringify([row.source, row.security])' 'JSON.stringify([row.id, row.security])'
  write_table "$AFTER" \
    '{"id": "T1", "source": "success_criteria:9", "security": "access"}' \
    '{"id": "T2", "source": "success_criteria:1", "security": "forgery"}'
  compare "$TREE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- the apply step's text ----------

flat_range() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1" | tr '\n' ' ' | tr -s ' '
}

need() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) printf 'missing: %s\n' "$2" >&2; return 1 ;;
  esac
}

# check_replan_security <root>: the Structural bullet snapshots tests.json
# before the re-spawn and runs the compare after step 4.5, and the security-row
# rule holds each lost row and keeps a restore only behind a passing step 4.5,
# since a restored row can point at a task the re-plan moved.
check_replan_security() {
  local structural rule
  structural="$(flat_range "$1/$AUDIT_REL" '- **Structural findings**' '**Security rows.**')"
  rule="$(flat_range "$1/$AUDIT_REL" '**Security rows.**' '**Interactive:**')"
  need "$structural" 'Copy `<PLAN_DIR>/tests.json` to `<PLAN_DIR>/tests.before-correction.json`, then re-run `plan.md` step 4' || return 1
  need "$structural" 'Then run `node .gaia/scripts/test-design/security-rows-lost.mjs --before <PLAN_DIR>/tests.before-correction.json --after <PLAN_DIR>/tests.json`' || return 1
  need "$structural" 'is held by the rule below. A non-zero exit is handled like a step 4.5 failure.' || return 1
  need "$rule" "A Structural re-plan's \`lost:\` line is held the same way: its item recommends restoring each missing row" || return 1
  need "$rule" 'as the planner would add it: an id the regenerated table does not use,' || return 1
  need "$rule" 'its `task` re-set to the latest regenerated task whose code its test needs' || return 1
  need "$rule" 'and that task'"'"'s phase `- Security writer:` line in `ORCHESTRATOR.md`.' || return 1
  need "$rule" 'Every restore re-runs step 4.5; when 4.5 fails, undo the restore and report the row as not restored.' || return 1
  need "$rule" 'In auto-mode, restore it and record it in `## Audit notes`, a failed restore included.' || return 1
}

@test "the Structural re-plan routes a lost security row to the review list" {
  run check_replan_security "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "red twin: a re-plan with no snapshot fails" {
  mutated_tree "$AUDIT_REL" 'Copy `<PLAN_DIR>/tests.json` to `<PLAN_DIR>/tests.before-correction.json`, then re-run' 'Re-run'
  run check_replan_security "$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == 'missing: '* ]]
}

@test "red twin: a re-plan that never runs the compare fails" {
  mutated_tree "$AUDIT_REL" 'Then run `node .gaia/scripts/test-design/security-rows-lost.mjs' 'Then read'
  run check_replan_security "$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == 'missing: '* ]]
}

@test "red twin: a lost row left off the security-row rule fails" {
  mutated_tree "$AUDIT_REL" "A Structural re-plan's \`lost:\` line is held the same way" 'A Structural re-plan is not held'
  run check_replan_security "$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == 'missing: '* ]]
}

@test "red twin: a restore with no step 4.5 rerun fails" {
  mutated_tree "$AUDIT_REL" 'Every restore re-runs step 4.5; when 4.5 fails, undo the restore and report the row as not restored.' 'Restore the row.'
  run check_replan_security "$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == 'missing: '* ]]
}

@test "red twin: a restore under the snapshot id fails" {
  mutated_tree "$AUDIT_REL" ' an id the regenerated table does not use,' ''
  run check_replan_security "$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == 'missing: '* ]]
}

@test "red twin: a restore keeping a task the re-plan removed fails" {
  mutated_tree "$AUDIT_REL" 'its `task` re-set to the latest regenerated task whose code its test needs' 'its snapshot `task`'
  run check_replan_security "$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == 'missing: '* ]]
}

@test "red twin: a restore leaving the phase's security writer line unchanged fails" {
  mutated_tree "$AUDIT_REL" ", and that task's phase \`- Security writer:\` line in \`ORCHESTRATOR.md\`." ' and that task doc'"'"'s `- Test:` line.'
  run check_replan_security "$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == 'missing: '* ]]
}
