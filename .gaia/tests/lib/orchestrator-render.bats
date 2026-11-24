#!/usr/bin/env bats
#
# Flow test: a planner's parts file, a README phase row and a task doc per
# phase are rendered into ORCHESTRATOR.md and KICKOFF.md, and plan-verify
# passes on the result. Refusals and byte-level substitution belong to the
# renderer and plan-verify suites.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RENDER="$REPO_ROOT_REAL/.gaia/scripts/spec/orchestrator-render.sh"
  VERIFY="$REPO_ROOT_REAL/.gaia/scripts/spec/plan-verify.sh"
  PLAN="$BATS_TEST_TMPDIR/plan"
  PARTS="$BATS_TEST_TMPDIR/parts.md"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  # Fixture ids the SPEC reader requires, assembled so this file holds no literal id.
  SCRATCH_SPEC_ID="$(printf '%s-%s' SPEC 901)"
  SCRATCH_FLOW_ID="$(printf '%s-%s' FLOW 902)"
  FLOW_TEST_PATH='.gaia/tests/lib/scratch-flow.bats'
  mkdir -p "$PLAN"
}

write_parts() {
  cat >"$PARTS" <<EOF2
## Title

Scratch plan
Type: feat
Slug: scratch thing

## Pushes

Push after each phase.

## Phase loop

Run each phase in order.

## Phase entries

**Phase 1, Build**

- Tasks: \`task-build\`

**Phase 2, Flow**

- Tasks: \`task-flow-scratch\`
- Run: \`bash .gaia/scripts/bats5.sh $FLOW_TEST_PATH < /dev/null\`

## Kickoff goal

Build the scratch thing.

## Kickoff outline

Build, then run the flow test.
EOF2
}

write_spec() {
  cat >"$SPEC" <<EOF2
---
spec_id: $SCRATCH_SPEC_ID
flows:
  - flow_id: $SCRATCH_FLOW_ID
    slug: scratch-flow
    name: A scratch flow
    why: Proves the rendered plan verifies
    test_path: $FLOW_TEST_PATH
---

# Scratch
EOF2
}

write_plan_files() {
  printf '# Plan\n\n| Phase | Tasks | Model | Split |\n|---|---|---|---|\n| Phase 1 | `task-build` | sonnet | none |\n| Phase 2 | `task-flow-scratch` | sonnet | none |\n' >"$PLAN/README.md"
  printf '# Build\n' >"$PLAN/task-build.md"
  printf '# Flow\n\n- Flow test (%s): %s\n' "$SCRATCH_FLOW_ID" "$FLOW_TEST_PATH" >"$PLAN/task-flow-scratch.md"
  printf 'status: ran\n' >"$PLAN/TEST-STAGE"
}

@test "a plan rendered from a parts file and a spec passes plan-verify" {
  write_parts
  write_spec
  write_plan_files

  run bash "$RENDER" "$PLAN" --parts "$PARTS" --audit unset --branch scratch-branch --spec "$SPEC"
  [ "$status" -eq 0 ]
  [ -s "$PLAN/ORCHESTRATOR.md" ]
  [ -s "$PLAN/KICKOFF.md" ]

  run bash "$VERIFY" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ]
}
