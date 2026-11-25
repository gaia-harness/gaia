#!/usr/bin/env bats
#
# The test stage writes the digest its review lens reads: after the stage's own
# pre-clear of the findings folder, the check script run with --digest exits 0
# and leaves the digest in that folder: it carries the fixture's
# behavior, its Tests line and its Flow test line, and the hash the script prints
# matches the written file. The digest's full content and refusals belong to
# test-stage-check.bats. Fixtures live under $BATS_TEST_TMPDIR.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI="$REPO_ROOT/.gaia/scripts/spec/test-stage-check.mjs"
  PLAN_DIR="$BATS_TEST_TMPDIR/plan"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  mkdir -p "$PLAN_DIR"
}

@test "the test stage writes a digest into its pre-cleared findings folder that carries the behavior, Tests line and Flow test line, and whose printed hash matches the file" {
  cat >"$SPEC" <<'SPEC'
---
spec_id: scratch
flows:
  - flow_id: scratch-flow
    slug: main
    name: The main journey.
---

# Title

## Behaviors

- **B1** (other): The footer shows the year.
  - Case: any visitor, GET / -> footer reads 2026.

## Next
SPEC
  printf '# one\n\n## Tests\n\n- Test (B1, unit, none): a.test.ts › footer year\n' >"$PLAN_DIR/task-one.md"
  printf '# two\n\nBody.\n\n- Flow test (scratch-flow): flow.spec.ts\n' >"$PLAN_DIR/task-two.md"
  printf '# Orch\n\n**Phase 1, one**\n\nfirst\n\n**Phase 2, closing**\n\nclosing text\n' >"$PLAN_DIR/ORCHESTRATOR.md"

  rm -rf "$PLAN_DIR/test-stage-findings" && mkdir -p "$PLAN_DIR/test-stage-findings"
  run node "$CLI" --plan-dir "$PLAN_DIR" --spec "$SPEC" --digest "$PLAN_DIR/test-stage-findings/digest.md"
  [ "$status" -eq 0 ]
  local digest="$PLAN_DIR/test-stage-findings/digest.md"
  [ "$output" = "$(shasum -a 256 "$digest" | cut -d' ' -f1)" ]
  grep -F -q 'The footer shows the year.' "$digest"
  grep -F -q 'Test (B1, unit, none): a.test.ts › footer year' "$digest"
  grep -F -q 'Flow test (scratch-flow): flow.spec.ts' "$digest"
}
