#!/usr/bin/env bats
#
# Flow: the test stage turns a planned SPEC's stated behaviors into a per-task
# test list the build writes. Drives the deterministic seams in order on a
# fixture plan folder: the stage check over the written Test and Flow test
# lines, the plan check while the record reads running, then again once it
# reads ran. Happy path only; refusals live in the suites that own them.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STAGE_CHECK="$REPO_ROOT_REAL/.gaia/scripts/spec/test-stage-check.mjs"
  PLAN_VERIFY="$REPO_ROOT_REAL/.gaia/scripts/spec/plan-verify.sh"
  PLANNER_MD="$REPO_ROOT_REAL/.claude/skills/gaia/references/plan/planner.md"
  PLAN="$BATS_TEST_TMPDIR/plan"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  mkdir -p "$PLAN"
  # Working-document ids are built from parts so this file holds none.
  SPEC_ID="$(printf '%s-%s' SPEC 901)"
  FLOW_ONE="$(printf '%s-%s' FLOW 901)"
  FLOW_TWO="$(printf '%s-%s' FLOW 902)"
  PATH_ONE='.gaia/tests/lib/first-journey.bats'
  PATH_TWO='.gaia/tests/lib/second-journey.bats'
}

# block_of <sentinel>: the block that sentinel opens in planner.md, with this
# fixture's plan directory and SPEC path substituted.
block_of() {
  local block
  block="$(awk -v want="$1" '
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

write_spec() {
  cat >"$SPEC" <<EOF2
---
spec_id: $SPEC_ID
flows:
  - flow_id: $FLOW_ONE
    slug: first-journey
    name: A reader opens the first journey
    why: The first journey is the main path
    test_path: $PATH_ONE
  - flow_id: $FLOW_TWO
    slug: second-journey
    name: A reader opens the second journey
    why: The second journey is the other path
    test_path: $PATH_TWO
---

# Sample

## Behaviors

- **B1** (access): A guest cannot read another account's orders.
  - Case: a guest requests an order of another account -> a 403 refusal.
- **B2** (refusal): An empty cart cannot be submitted.
  - Case: a user submits zero items -> a message naming the empty cart.
- **B3** (other): The order total shows two decimals.
  - Case: a total of 5 -> 5.00 is shown.
EOF2
}

# write_plan_folder: the verified plan folder before the test stage runs.
write_plan_folder() {
  local sentinel
  cat >"$PLAN/README.md" <<'EOF2'
# Plan

| Phase | Tasks | Model | Split |
|---|---|---|---|
| Phase 1 | `task-build-access`, `task-build-rest` | sonnet | none |
EOF2
  {
    printf '# Orchestrator\n\n**Phase 1, build.**\n\n## Steps\n\n'
    for sentinel in resume-detection yield-handling gate-retry security-writer simplify-pass flow-checks wiki-promotion code-audit post-clearance; do
      block_of "<!-- gaia:orchestrator-step $sentinel -->" || return 1
      printf '\nprose between steps\n\n'
    done
    printf '<!-- gaia:orchestrator-step post-merge-close -->\n'
  } >"$PLAN/ORCHESTRATOR.md"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  printf '# Access\n\n## Acceptance criteria\n\n- guests are refused\n' >"$PLAN/task-build-access.md"
  printf '# Rest\n\n## Acceptance criteria\n\n- the cart refuses, the total formats\n' >"$PLAN/task-build-rest.md"
}

# write_test_stage <status>: the plan's TEST-STAGE record.
write_test_stage() {
  printf 'status: %s\ndate: 2026-01-01T00:00:00Z\n' "$1" >"$PLAN/TEST-STAGE"
}

# stage_writes: what the test stage writes into the plan folder after the
# running record: the build tasks' Test lines, then the closing phase (one task
# doc per flow, its README row and ORCHESTRATOR entry with the runner lines,
# and the Security writer line on the phase owning the access test).
stage_writes() {
  local separator=' › ' rewritten="$BATS_TEST_TMPDIR/orchestrator.new"
  printf '\n## Tests\n\n- Test (B1, shell, access): .gaia/tests/lib/orders.bats%sa guest is refused another account order\n' "$separator" >>"$PLAN/task-build-access.md"
  printf '\n## Tests\n\n- Test (B2, shell, none): .gaia/tests/lib/cart.bats%san empty cart is refused\n' "$separator" >>"$PLAN/task-build-rest.md"
  printf '# Flow one\n\n## Tests\n\n- Flow test (%s): %s\n' "$FLOW_ONE" "$PATH_ONE" >"$PLAN/task-flow-first.md"
  printf '# Flow two\n\n## Tests\n\n- Flow test (%s): %s\n' "$FLOW_TWO" "$PATH_TWO" >"$PLAN/task-flow-second.md"
  printf '| Phase 2 | `task-flow-first`, `task-flow-second` | sonnet | none |\n' >>"$PLAN/README.md"
  awk -v first="$(basename "$PATH_ONE")" -v second="$(basename "$PATH_TWO")" '
    /^\*\*Phase 1, / { print; print "- Security writer: 1 tests"; next }
    /^## Steps/ {
      print "**Phase 2, flows.**"
      print "Gate: bash .gaia/scripts/bats5.sh .gaia/tests/lib/" first " < /dev/null"
      print "Gate: bash .gaia/scripts/bats5.sh .gaia/tests/lib/" second " < /dev/null"
      print ""
    }
    { print }' "$PLAN/ORCHESTRATOR.md" >"$rewritten"
  mv "$rewritten" "$PLAN/ORCHESTRATOR.md"
}

@test "a planned SPEC's test lists pass the stage check and the plan re-verifies with its closing flow phase" {
  write_spec
  write_plan_folder
  write_test_stage running
  stage_writes

  run node "$STAGE_CHECK" --plan-dir "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run bash "$PLAN_VERIFY" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ]
  head -n 1 "$PLAN/TEST-STAGE" | grep -qx 'status: running'

  write_test_stage ran
  run bash "$PLAN_VERIFY" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ]
}
