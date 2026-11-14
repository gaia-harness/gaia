#!/usr/bin/env bats
#
# The approved test-design table journey, driven at the command entry points:
# the plan marker, the requirement keys a SPEC and its audit demand, plan
# verification of a planner output whose table cites every key, and the approve
# step that freezes the table. Refusals are owned by test-table.bats and
# plan-verify.bats.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLAN_VERIFY="$REPO_ROOT_REAL/.gaia/scripts/spec/plan-verify.sh"
  REQUIREMENT_KEYS="$REPO_ROOT_REAL/.gaia/scripts/spec/requirement-keys.sh"
  TEST_TABLE="$REPO_ROOT_REAL/.gaia/scripts/test-design/test-table.mjs"
  PLANNER_MD="$REPO_ROOT_REAL/.claude/skills/gaia/references/plan/planner.md"
  SPEC_DIRECTORY="$BATS_TEST_TMPDIR/spec"
  SPEC="$SPEC_DIRECTORY/SPEC.md"
  AUDIT="$SPEC_DIRECTORY/AUDIT.md"
  PLAN="$BATS_TEST_TMPDIR/plan"
  mkdir -p "$SPEC_DIRECTORY" "$PLAN"
  SPEC_ID="SPEC-""901"
  FLOW_ONE_ID="FLOW-""901"
  FLOW_TWO_ID="FLOW-""902"
  FLOW_ONE_PATH='.gaia/tests/lib/first-flow.bats'
  FLOW_TWO_PATH='.gaia/tests/lib/second-flow.bats'
  UNIT_PATH='apps/web/app/utils/price.test.ts'
  SENTINEL_NAMES=(resume-detection yield-handling gate-retry security-writer simplify-pass flow-checks drift-check wiki-promotion code-audit post-clearance post-merge-close)
}

# write_spec_and_audit: a SPEC with two command flows, a criterion, scope
# boundaries, an answered clarification, and a sibling audit with one
# plan-time directive.
write_spec_and_audit() {
  cat >"$SPEC" <<EOF2
---
spec_id: $SPEC_ID
flows:
  - flow_id: $FLOW_ONE_ID
    slug: first-flow
    name: The first command flow runs
    why: The first flow matters
    test_path: $FLOW_ONE_PATH
  - flow_id: $FLOW_TWO_ID
    slug: second-flow
    name: The second command flow runs
    why: The second flow matters
    test_path: $FLOW_TWO_PATH
success_criteria:
  - The command prints a result
scope_boundaries:
  always:
    - Keep output stable
  never:
    - Print a secret
clarifications:
  answered:
    - question: Which format
      answer: JSON
  pending: []
---

# Sample
EOF2
  cat >"$AUDIT" <<'EOF2'
# Audit

## Plan-time directives (no SPEC change)

1. Keep the exit codes unchanged.
EOF2
}

# block_of <sentinel>: the fenced block of planner.md that sentinel opens, with
# the placeholders replaced by this fixture's values.
block_of() {
  local want="$1" block
  block="$(awk -v want="$want" '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t ~ /^```/ {
      if (in_fence) { if (hit) { printf "%s", buffer; exit } in_fence = 0 }
      else { in_fence = 1; buffer = ""; hit = 0 }
      next
    }
    in_fence {
      if (t == want) hit = 1
      line = $0
      sub(/^ {6}/, "", line)
      buffer = buffer line "\n"
    }' "$PLANNER_MD")"
  [ -n "$block" ] || return 1
  block="${block//\{PLAN_DIR\}/$PLAN}"
  printf '%s\n' "${block//\{SPEC_PATH\}/$SPEC}"
}

# table_row <id> <source> <file> <title> <task> <action> <security> [<caseKey>]
table_row() {
  local case_key=''
  [ -z "${8:-}" ] || case_key=",\"caseKey\":\"$8\""
  printf '{"id":"%s","source":"%s","case":"c","file":"%s","title":"%s","layer":"unit","task":"%s","action":"%s","security":"%s"%s}' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$case_key"
}

# write_plan_folder: a planner output that passes plan verification: README
# with phase rows and the rendered table, task docs with their test lines, an
# ORCHESTRATOR built from planner.md's blocks, and a table citing every key.
write_plan_folder() {
  local name sentinel
  cat >"$PLAN/README.md" <<'EOF2'
# Plan

| Phase | Tasks | Model | Split |
|---|---|---|---|
| Phase 1 | `task-build` | sonnet | none |
| Phase 2 | `task-flow-first`, `task-flow-second` | sonnet | none |

## Test design

| id | source | case | file | title | layer | task | action | security |
|---|---|---|---|---|---|---|---|---|
| T1 | flow:first-flow | c | .gaia/tests/lib/first-flow.bats | the first command flow runs | unit | task-flow-first | new | none |
EOF2
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  {
    printf '# Build\n\n'
    printf -- '- Test: %s › reuses the price case\n' "$UNIT_PATH"
    printf -- '- Test: %s › extends the format case\n' "$UNIT_PATH"
    printf -- '- Test: %s › changes the exit codes case\n' "$UNIT_PATH"
    printf -- '- Test: %s › retires the old exit codes case\n' "$UNIT_PATH"
    printf -- '- Test: %s › refuses to print a secret\n' "$UNIT_PATH"
    printf -- '- Test: %s › keeps output stable\n' "$UNIT_PATH"
  } >"$PLAN/task-build.md"
  printf '# First flow\n\n- Flow test (%s): %s\n- Test: %s › the first command flow runs\n' "$FLOW_ONE_ID" "$FLOW_ONE_PATH" "$FLOW_ONE_PATH" >"$PLAN/task-flow-first.md"
  printf '# Second flow\n\n- Flow test (%s): %s\n- Test: %s › the second command flow runs\n' "$FLOW_TWO_ID" "$FLOW_TWO_PATH" "$FLOW_TWO_PATH" >"$PLAN/task-flow-second.md"
  {
    printf '# Orchestrator\n\n'
    printf '**Phase 1, build.**\n- Security writer: 1 rows (T7)\n\n'
    printf '**Phase 2, flows.**\n'
    printf 'Gate: bash .gaia/scripts/bats5.sh %s < /dev/null\n' "$FLOW_ONE_PATH"
    printf 'Gate: bash .gaia/scripts/bats5.sh %s < /dev/null\n\n' "$FLOW_TWO_PATH"
    printf '## Steps\n\n'
    for name in "${SENTINEL_NAMES[@]}"; do
      sentinel="<!-- gaia:orchestrator-step $name -->"
      case "$name" in
        post-merge-close) printf '%s\n' "$sentinel" ;;
        *) block_of "$sentinel" || return 1 ;;
      esac
      printf '\nprose between steps\n\n'
    done
  } >"$PLAN/ORCHESTRATOR.md"
  printf 'schema: 1\n' >"$PLAN/TEST-DESIGN"
  printf '{"schema":1,"rows":[%s,%s,%s,%s,%s,%s,%s,%s]}\n' \
    "$(table_row T1 flow:first-flow "$FLOW_ONE_PATH" 'the first command flow runs' task-flow-first new none)" \
    "$(table_row T2 flow:second-flow "$FLOW_TWO_PATH" 'the second command flow runs' task-flow-second new none)" \
    "$(table_row T3 success_criteria:0 "$UNIT_PATH" 'reuses the price case' task-build reuse none)" \
    "$(table_row T4 clarifications:0 "$UNIT_PATH" 'extends the format case' task-build extend none json)" \
    "$(table_row T5 directive:1 "$UNIT_PATH" 'changes the exit codes case' task-build change none)" \
    "$(table_row T6 directive:1 "$UNIT_PATH" 'retires the old exit codes case' task-build retire none)" \
    "$(table_row T7 scope_boundaries:never:0 "$UNIT_PATH" 'refuses to print a secret' task-build new secret)" \
    "$(table_row T8 scope_boundaries:always:0 "$UNIT_PATH" 'keeps output stable' task-build new none)" \
    >"$PLAN/tests.json"
}

@test "a planned table passes verification, then freezes at approval and still passes" {
  local expected_hash
  write_spec_and_audit
  write_plan_folder

  run bash "$REQUIREMENT_KEYS" --spec "$SPEC" --audit "$AUDIT"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$output" = "$(printf '%s\n' clarifications:0 directive:1 flow:first-flow flow:second-flow scope_boundaries:always:0 scope_boundaries:never:0 success_criteria:0)" ] || { echo "$output" >&2; return 1; }

  run bash "$PLAN_VERIFY" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }

  run node "$TEST_TABLE" approve --plan-dir "$PLAN"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  cmp -s "$PLAN/tests.json" "$PLAN/tests.approved.json" || { echo 'approved copy differs from tests.json' >&2; return 1; }
  expected_hash="$(shasum -a 256 "$PLAN/tests.approved.json" | awk '{print $1}')"
  grep -qxF "approved_sha256: $expected_hash" "$PLAN/TEST-DESIGN" || { cat "$PLAN/TEST-DESIGN" >&2; return 1; }

  run bash "$PLAN_VERIFY" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}
