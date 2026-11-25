#!/usr/bin/env bats
#
# Doc-conformance suite for the two dispatch lines the sub-agent context
# checkpoint hook (.claude/hooks/context-checkpoint-subagent.sh) parses: the
# executor prompt template in
# .claude/skills/gaia/references/plan/orchestrator-template.md and the planner
# dispatch fence in .claude/skills/gaia/references/plan.md must
# each end with a `Yield handoff: <path>` line in the dispatcher's shape, or
# the hook never sees the opt-in.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPLATE_REL=".claude/skills/gaia/references/plan/orchestrator-template.md"
  PLAN_REL=".claude/skills/gaia/references/plan.md"
}

# range_of <file> <start fixed string> <end fixed string>: the lines from the
# first start match up to, not including, the first end match after it. An
# end that never matches runs to the end of the file.
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1"
}

# trim_lines: strip leading and trailing whitespace from every line on stdin.
trim_lines() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# in_order <text> <anchor>...: every anchor appears in <text>, each after the
# one before it.
in_order() {
  local rest="$1" anchor after
  shift
  for anchor in "$@"; do
    after="${rest#*"$anchor"}"
    if [ "$after" = "$rest" ]; then
      printf 'anchor missing or out of order: %s\n' "$anchor" >&2
      return 1
    fi
    rest="$after"
  done
}

# need_text <name> <text>: the region was found and is not empty.
need_text() {
  [ -n "$2" ] || { printf 'region not found: %s\n' "$1" >&2; return 1; }
}

check_executor_template_yield_line() {
  local range
  range="$(range_of "$REPO_ROOT/$TEMPLATE_REL" '## Sub-agent invocation' '## Orchestrator-owned git flow' | trim_lines)"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    'Yield exemption: only when' \
    'Yield handoff: {PLAN_DIR}/handoffs/phase-<N>-task-<T>-yield-<k>.md' \
    "the dispatch prompt's final line" || return 1
}

check_step4_fence_last_line() {
  local fence last
  fence="$(range_of "$REPO_ROOT/$PLAN_REL" '### 4. Spawn planning agent' '### 4.5.' | awk '
    /^```/ { if (inside) exit; inside = 1; next }
    inside { print }')"
  need_text 'step 4 dispatch fence' "$fence" || return 1
  last="$(printf '%s\n' "$fence" | awk 'NF { line = $0 } END { print line }')"
  [ "$last" = 'Yield handoff: <absolute PLAN_DIR>/handoffs/planner-yield-1.md' ] || {
    printf 'the dispatch fence does not end with the planner yield handoff line\n' >&2
    return 1
  }
}

@test "UAT-009: the executor template ends with the planned yield handoff line" {
  check_executor_template_yield_line
}

@test "UAT-013: the step-4 dispatch fence ends with the planner yield handoff line" {
  check_step4_fence_last_line
}
