#!/usr/bin/env bats
# Flow test: a spec run's code map reaches every later spec, plan and
# test-stage dispatch as an index. Walks the handoff from the writer (5e) to the
# owning section, the lens slot, each caller that fills it and the planner and
# plan-step readers, asserting that every hop's pointer resolves.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFS="$ROOT/.claude/skills/gaia/references"
  CLARIFY_MD="$REFS/spec/clarify-loop.md"
  LENS_MD="$REFS/spec/lens-dispatch.md"
  AUDIT_MD="$REFS/spec/audit.md"
  DECOMP_MD="$REFS/plan/decomposition-audit.md"
  TEST_STAGE_MD="$REFS/test-stage.md"
  PLANNER_MD="$REFS/plan/planner.md"
  PLAN_MD="$REFS/plan.md"
}

# section_of <file> <heading line> [<stop prefix>]
# Prints the section from its heading through the line before the next line
# that starts with the stop prefix (default `## `).
section_of() {
  awk -v heading="$2" -v stop="${3:-## }" '
    $0 == heading { inside = 1; print; next }
    inside && index($0, stop) == 1 { exit }
    inside { print }
  ' "$1"
}

@test "the writer hands its append to the code map section and that section exists" {
  section_of "$CLARIFY_MD" "## 5e. Research subagent dispatch" | grep -qF '## The code map' || return 1
  grep -qxF '## The code map' "$CLARIFY_MD"
}

@test "the lens slot row points to the code map section that resolves" {
  section_of "$LENS_MD" "## Caller slots" | grep -F '<CODE_MAP_PATH>' | grep -qF 'clarify-loop.md` `## The code map`' || return 1
  grep -qxF '## The code map' "$CLARIFY_MD"
}

@test "each caller fills the lens slot" {
  section_of "$AUDIT_MD" "## The wave" | grep -qF '<CODE_MAP_PATH>' || return 1
  section_of "$AUDIT_MD" "## The fixer" | grep -qF '<CODE_MAP_PATH>' || return 1
  section_of "$DECOMP_MD" "## 4.6a. Dispatch the lens auditors" | grep -qF '<CODE_MAP_PATH>' || return 1
  section_of "$TEST_STAGE_MD" "## Checks" | grep -qF '<CODE_MAP_PATH>'
}

@test "the planner and the plan step both read the code map file" {
  section_of "$PLANNER_MD" "## Inputs" | grep -qF 'CODE-MAP.json' || return 1
  section_of "$PLAN_MD" "#### 1a. Detect SPEC reference" "### " | grep -qF 'CODE-MAP.json'
}
