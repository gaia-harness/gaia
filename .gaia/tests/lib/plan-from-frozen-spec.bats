#!/usr/bin/env bats
#
# Flow test: a frozen SPEC becomes a reviewed task breakdown whose KICKOFF
# reaches an audited merge without a test table. Drives the deterministic seams
# of that journey (plan-verify.sh, flow-coverage.sh), happy path only, with the
# test stage skipped. Every SPEC and flow id is built at runtime from parts.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_MD="$REPO_ROOT_REAL/.claude/skills/gaia/references/plan/planner.md"
  VERIFY="$REPO_ROOT_REAL/.gaia/scripts/spec/plan-verify.sh"
  COVERAGE="$REPO_ROOT_REAL/.gaia/scripts/spec/flow-coverage.sh"
  PLAN="$BATS_TEST_TMPDIR/plan"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  FIXTURE_REPO="$BATS_TEST_TMPDIR/repo"
  SPEC_PREFIX="SP""EC"
  FLOW_PREFIX="FL""OW"
  SPEC_NUMBER="$((900 + 7))"
  FIRST_FLOW="$FLOW_PREFIX-$((900 + 1))"
  SECOND_FLOW="$FLOW_PREFIX-$((900 + 2))"
  mkdir -p "$PLAN" "$FIXTURE_REPO"
}

# block_of <sentinel>: the block that sentinel opens in planner.md, with the
# plan-directory and SPEC-path placeholders replaced by this fixture's values.
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

@test "a frozen SPEC's plan with no test table verifies and passes flow coverage with the test stage skipped" {
  local step base_ref
  local sentinels=(resume-detection yield-handling gate-retry security-writer simplify-pass flow-checks wiki-promotion code-audit post-clearance post-merge-close)

  cat >"$SPEC" <<EOF2
---
spec_id: $SPEC_PREFIX-$SPEC_NUMBER
title: Sample
flows:
  - flow_id: $FIRST_FLOW
    slug: first-check
    name: The first check holds
    why: A silent pass would hide a regression
    test_path: .gaia/tests/lib/first-check.bats
  - flow_id: $SECOND_FLOW
    slug: second-check
    name: The second check holds
    why: A silent pass would hide a regression
    test_path: .gaia/tests/lib/second-check.bats
---

# Sample
EOF2

  cat >"$PLAN/README.md" <<EOF2
# Plan

## Source SPEC

$SPEC

| Phase | Tasks | Model | Split |
|---|---|---|---|
| Phase 1 | \`task-alpha\`, \`task-beta\` | sonnet | none |
EOF2
  {
    printf '# Orchestrator\n\n## Steps\n\n'
    for step in "${sentinels[@]}"; do
      block_of "<!-- gaia:orchestrator-step $step -->" || return 1
      printf '\nprose between steps\n\n'
    done
  } >"$PLAN/ORCHESTRATOR.md"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  printf '# Alpha\n\n- builds the first part\n' >"$PLAN/task-alpha.md"
  printf '# Beta\n\n- builds the second part\n' >"$PLAN/task-beta.md"
  printf 'status: skipped\ndate: 2026-01-01T00:00:00Z\n' >"$PLAN/TEST-STAGE"
  [ ! -e "$PLAN/TEST-DESIGN.md" ] || return 1
  [ ! -e "$PLAN/tests.json" ] || return 1

  run bash "$VERIFY" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "plan-verify: $output" >&2; return 1; }

  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.email test@example.com
  git -C "$FIXTURE_REPO" config user.name test
  git -C "$FIXTURE_REPO" config commit.gpgsign false
  printf 'base\n' >"$FIXTURE_REPO/base.txt"
  git -C "$FIXTURE_REPO" add -A
  git -C "$FIXTURE_REPO" commit -q -m base
  base_ref="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
  printf 'branch\n' >"$FIXTURE_REPO/branch.txt"
  git -C "$FIXTURE_REPO" add -A
  git -C "$FIXTURE_REPO" commit -q -m branch

  run bash "$COVERAGE" --spec "$SPEC" --root "$FIXTURE_REPO" --plan-dir "$PLAN" --base "$base_ref"
  [ "$status" -eq 0 ] || { echo "flow-coverage: $output" >&2; return 1; }
  [ "$(printf '%s\n' "$output" | grep -c '^flow-coverage: gap:')" -eq 2 ] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -qF "flow-coverage: gap: $FIRST_FLOW has no flow test"
  printf '%s\n' "$output" | grep -qF "flow-coverage: gap: $SECOND_FLOW has no flow test"
}
