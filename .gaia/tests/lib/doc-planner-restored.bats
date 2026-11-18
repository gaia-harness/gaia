#!/usr/bin/env bats
#
# Doc pins for the planner reference after its return to the earlier planner
# text: it carries no red-gate machinery and no per-guard criterion, it plans
# no tests (the test stage adds them after the plan review), and it keeps the
# execution blocks a plan run needs, among them the code audit opening with
# the worthiness step and the gate-retry and yield-handling blocks the Task
# Orchestration wiki page points at. Prose-to-prose only: whether a generated
# ORCHESTRATOR.md matches these blocks is plan-verify's own suite.
#
# GAIA_PLANNER_MD overrides the planner path so a mutated scratch copy can be
# driven through the same checks; it defaults to the real file.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016  # the backticks in every needle are literal Markdown code spans

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
PLANNER_MD="${GAIA_PLANNER_MD:-$REPO_ROOT/.claude/skills/gaia/references/plan/planner.md}"
TASK_ORCHESTRATION_MD="$REPO_ROOT/wiki/concepts/Task Orchestration.md"

# The kept orchestrator sentinel set, in the order the planner lists it.
KEPT_SENTINELS=(
  resume-detection
  yield-handling
  gate-retry
  security-writer
  simplify-pass
  flow-checks
  wiki-promotion
  code-audit
  post-clearance
  post-merge-close
)

# Every line outside a fenced block.
outside_fences() {
  awk '/^[ \t]*```/ { inside = !inside; next } !inside' "$PLANNER_MD"
}

# fenced_block <name>: the fenced block whose sentinel line names <name>,
# every line trimmed.
fenced_block() {
  awk -v want="<!-- gaia:orchestrator-step $1 -->" '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t ~ /^```/ {
      if (inside) { if (hit) { printf "%s", buffer; exit } inside = 0 }
      else { inside = 1; buffer = ""; hit = 0 }
      next
    }
    inside { if (t == want) hit = 1; buffer = buffer t "\n" }
  ' "$PLANNER_MD"
}

# The sentinel names in file order, each one only when it sits inside a fence.
fenced_sentinels() {
  awk '
    /^[ \t]*```/ { inside = !inside; next }
    inside && match($0, /<!-- gaia:orchestrator-step [a-z-]+ -->/) {
      name = substr($0, RSTART + 28, RLENGTH - 32)
      print name
    }
  ' "$PLANNER_MD"
}

@test "restored planner carries no red gate, frontend command or per-guard criterion" {
  [ -s "$PLANNER_MD" ]
  # No RED recording mandate and no RED gate, in any casing of the gate.
  grep -nE '\bRED\b' "$PLANNER_MD" && return 1
  grep -niE '\bred[ -]gate' "$PLANNER_MD" && return 1
  grep -niF "failing run (RED)" "$PLANNER_MD" && return 1
  # No command example aimed at the old frontend package folder.
  grep -nF 'pnpm -C frontend' "$PLANNER_MD" && return 1
  # No criterion per guard that drives it into its failing state.
  grep -niF 'one criterion per guard' "$PLANNER_MD" && return 1
  grep -niF 'into its failing state' "$PLANNER_MD" && return 1
  # The audit input and its plan-time directives paragraph stay.
  grep -qF -- "- \`AUDIT_PATH\`: the absolute path of the SPEC's adversarial audit, or \`unset\`." "$PLANNER_MD"
  grep -F "When \`AUDIT_PATH\` is set:" "$PLANNER_MD" | grep -qF '`## Plan-time directives`'
}

@test "planner keeps the code-audit and post-clearance blocks with the worthiness late pass" {
  local code_audit post_clearance worthiness_at resolver_at actual expected
  code_audit="$(fenced_block code-audit)"
  post_clearance="$(fenced_block post-clearance)"
  [ -n "$code_audit" ]
  [ -n "$post_clearance" ]

  # The code audit runs the worthiness step before it resolves the members.
  worthiness_at="$(printf '%s' "$code_audit" | grep -nF 'read `.claude/skills/gaia/references/worthiness-step.md` and run it' | head -n 1 | cut -d: -f1)"
  resolver_at="$(printf '%s' "$code_audit" | grep -nF 'resolve-audit-members.sh' | head -n 1 | cut -d: -f1)"
  [ -n "$worthiness_at" ]
  [ -n "$resolver_at" ]
  [ "$worthiness_at" -le "$resolver_at" ]
  [[ "$code_audit" == *'First read `.claude/skills/gaia/references/worthiness-step.md`'* ]]
  # Its late pass comes from the worthiness step's own section.
  [[ "$code_audit" == *'the late pass from `.claude/skills/gaia/references/worthiness-step.md` `## The late pass`'* ]]
  [[ "$post_clearance" == *'post-audit-status.sh'* ]]

  # No drift-check sentinel or reference remains.
  grep -nF 'orchestrator-step drift-check' "$PLANNER_MD" && return 1
  grep -nF 'drift-check.md' "$PLANNER_MD" && return 1

  # Each kept sentinel sits in a fence exactly once, in the kept order.
  actual="$(fenced_sentinels)"
  expected="$(printf '%s\n' "${KEPT_SENTINELS[@]}")"
  [ "$actual" = "$expected" ] || {
    printf 'fenced sentinels:\n%s\nwant:\n%s\n' "$actual" "$expected" >&2
    return 1
  }
}

@test "planner plans no tests" {
  local outside first_read
  # No test table, its marker or its procedure anywhere in the file.
  grep -nE 'tests\.json|TEST-DESIGN|test-table' "$PLANNER_MD" && return 1
  outside="$(outside_fences)"
  [ -n "$outside" ]
  # No test-line rule and no test-design README section outside the kept
  # blocks (the gate-retry and flow-checks blocks name the test stage's Flow
  # test lines on purpose).
  printf '%s' "$outside" | grep -nE '`- (Test|Flow test|Pin update|Delete)[ :(`]' && return 1
  printf '%s' "$outside" | grep -nF '## Test design' && return 1
  # No closing flow-test phase paragraph of the planner's own.
  printf '%s' "$outside" | grep -nF '**The closing flow-test phase' && return 1
  # The planner's opening read names neither the doctrine nor a table rule.
  first_read="$(awk '/^## Plan files/ { on = 1; next } on && NF { print; exit }' "$PLANNER_MD")"
  [[ "$first_read" == 'First, read `wiki/concepts/Task Orchestration.md`.' ]]
  # The test stage owns the tests and the closing phase, by one pointer.
  printf '%s' "$outside" | grep -F '**The plan names no test.**' | grep -qF '`.claude/skills/gaia/references/test-stage.md`'
}

@test "planner keeps the phase gate retry and yield handling blocks the wiki points at" {
  local outside yield_block retry_block flow_block
  outside="$(outside_fences)"
  # The wiki's stop-conditions step names the two owners by name.
  grep -F '4. **Stop conditions.**' "$TASK_ORCHESTRATION_MD" | grep -F 'the Stop conditions bullet' | grep -qF 'the Phase gate retry block'

  # Each owner is one placement bullet outside the fences.
  [ "$(printf '%s\n' "$outside" | grep -cF -- '- **Sub-agent yield handling.** Place this block inside the phase loop')" -eq 1 ]
  [ "$(printf '%s\n' "$outside" | grep -cF -- '- **Phase gate retry.** A plan step never states its own retry or halt rule for a gate failure; the gate-retry block owns which failures retry.')" -eq 1 ]
  [ "$(printf '%s\n' "$outside" | grep -cF -- '- **Stop conditions.** On any sub-agent failure, or a quality-gate failure the phase gate retry does not settle')" -eq 1 ]

  # The yield-handling block is the current text, which exempts a gate retry.
  yield_block="$(fenced_block yield-handling)"
  [[ "$yield_block" == *'Every task executor dispatch except a phase gate retry opts into the sub-agent context checkpoint'* ]]
  [[ "$yield_block" == *'## Phase N, <title> (YIELD k)'* ]]

  # The gate-retry block writes the GATE RETRY ledger block and keeps its
  # flow-test arm.
  retry_block="$(fenced_block gate-retry)"
  [[ "$retry_block" == *'## Phase N, <title> (GATE RETRY k)'* ]]
  [[ "$retry_block" == *'- **Flow-test arm.** A failing flow test in the closing phase'* ]]

  # The flow checks keep their Flow test fixer map.
  flow_block="$(fenced_block flow-checks)"
  [[ "$flow_block" == *'Map each stdout failure line to the closing-phase task whose `Flow test` line names its flow or its test path.'* ]]
}
