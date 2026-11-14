#!/usr/bin/env bats
#
# Doc-conformance suite for the planner's testing-trophy behavior.
#
# .claude/skills/gaia/references/plan/planner.md tells a planner to name
# behaviors and the acceptance tests that own them, to drive a guard red at the
# lowest layer that shows the refusal (an absence requirement included), to
# assert every case of a multi-case SPEC row but a non-guard flow case (a
# compound condition one case per part, an order-of-checks row one per adjacent
# pair), to cut
# build phases as vertical slices, and to bound the tests a task executor writes. The tdd skill's loop carries the
# matching limit. This suite pins that text, the decomposition audit's SPEC
# coverage lens that checks the plan per case, and the ORCHESTRATOR phase-entry
# form the phase-ownership check reads.
#
# Method: every check takes a root directory and reads the planner reference or
# the tdd skill from it; each red twin mutates one substring of a scratch copy,
# proves the copy changed, and runs the same check against it. Presence and
# absence match on whitespace-normalized text.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  TDD_REL=".claude/skills/tdd/SKILL.md"
  AUDIT_REL=".claude/skills/gaia/references/plan/decomposition-audit.md"
  LIMIT_CLAUSE='**The prompt template MUST also limit the tests a sub-agent writes**'
}

# ---------- helpers ----------

# flat <file>: the file's text with newlines and runs of spaces collapsed.
flat() { tr '\n' ' ' <"$1" | tr -s ' '; }

# has <text> <needle>: the fixed needle occurs in the text.
has() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

need() {
  has "$1" "$2" || { printf 'missing: %s\n' "$2" >&2; return 1; }
}

lacks() {
  has "$1" "$2" && { printf 'present, must be absent: %s\n' "$2" >&2; return 1; }
  return 0
}

# range_of <file> <start fixed string> <end fixed string>: the lines from the
# first start match up to, not including, the first end match after it.
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1"
}

# mutated_tree <relpath> <old> <new>: copy planner.md, the decomposition audit
# and the tdd skill into a
# scratch tree (TREE), replace the first fixed-string <old> in <relpath> with
# <new>, and prove the copy changed.
mutated_tree() {
  local rel="$1" old="$2" new="$3" file content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for file in "$PLANNER_REL" "$AUDIT_REL" "$TDD_REL"; do
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
  return 0
}

red() {
  local check="$1"
  shift
  mutated_tree "$@" || return 1
  run "$check" "$TREE"
  [ "$status" -ne 0 ] || { printf 'check %s still passed on the mutated copy\n' "$check" >&2; return 1; }
  [ -n "$output" ] || { printf 'check %s failed without a reason\n' "$check" >&2; return 1; }
}

green() {
  run "$1" "$REPO_ROOT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

# ---------- checks (each takes a root and returns non-zero with a reason) ----------

check_acceptance_text() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" 'Name the behavior the task delivers and the one acceptance test that owns it' || return 1
  need "$text" 'never left to a closing-phase flow test' || return 1
  need "$text" 'not a list of tests per function' || return 1
  need "$text" 'at the lowest layer that shows the refusal' || return 1
  need "$text" '.claude/rules/guards-must-fail.md' || return 1
  lacks "$text" 'One criterion per guard, refusal, or gate' || return 1
}

check_executor_limit() {
  local range
  range="$(range_of "$1/$PLANNER_REL" '**Sub-agent invocation:**' '**Orchestrator-owned git flow.**' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$range" ] || { printf 'executor template range not found\n' >&2; return 1; }
  need "$range" "$LIMIT_CLAUSE" || return 1
  need "$range" 'a new test only for a behavior or acceptance test its task doc names' || return 1
}

check_executor_lint() {
  local range
  range="$(range_of "$1/$PLANNER_REL" '**Sub-agent invocation:**' '**Orchestrator-owned git flow.**' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$range" ] || { printf 'executor template range not found\n' >&2; return 1; }
  need "$range" "**The prompt template MUST also require linting the sub-agent's own files before it returns**, with \`pnpm -C <package dir> exec eslint <its own files>\`, the paths relative to the package and no fix flag" || return 1
  need "$range" 'it rewrites its edit until lint reports no problem its edit caused, error or warning, but `prettier/prettier`' || return 1
  need "$range" 'and a problem its edit did not cause, such as an unresolved import of a file a sibling task has not written yet, goes under `### Findings`, not chased.' || return 1
}

check_vertical_slicing() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" '**Cut build phases as vertical slices.** Each build phase delivers a behavior end to end.' || return 1
}

check_phase_entry_form() {
  local bullet
  bullet="$(range_of "$1/$PLANNER_REL" '- **Phase order**' '- **Worthiness step.**' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$bullet" ] || { printf 'Phase order bullet not found\n' >&2; return 1; }
  need "$bullet" '**Phase <N>, <title>' || return 1
}

check_tdd_loop() {
  local text
  text="$(flat "$1/$TDD_REL")"
  need "$text" 'Write a new test only for those behaviors and their acceptance tests' || return 1
  need "$text" 'plus a unit test where `.claude/doctrine/testing.md` allows one' || return 1
  lacks "$text" 'For each remaining behavior' || return 1
  lacks "$text" 'One test at a time' || return 1
}

check_task_doc_test_naming() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" 'A task doc names a test only for the flow test it owns in the closing phase' || return 1
  need "$text" 'a unit test for logic meeting both unit-test conditions (`wiki/decisions/Test Layering.md`), stating how each condition holds' || return 1
  need "$text" 'Any other test worth having goes under `## Follow-ups` in `README.md`, never into a task doc.' || return 1
}

check_absence_and_cases() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" 'An absence requirement (a value never exposed, sent, stored or rendered) counts as a guard' || return 1
  need "$text" 'names a test asserting the absence while the value is present upstream' || return 1
  need "$text" 'Every case a multi-case SPEC row lists is asserted by a test this task names unless it is no guard and the closing flow asserts it' || return 1
}

# ---------- tests ----------

@test "planner names behaviors and acceptance tests and drops the per-guard criterion line" {
  green check_acceptance_text
}

@test "red twin: restoring the per-guard criterion line fails" {
  red check_acceptance_text "$PLANNER_REL" 'not a list of tests per function' 'not a list of tests per function. One criterion per guard, refusal, or gate'
}

@test "red twin: leaving a refusal to the closing-phase flow test fails" {
  red check_acceptance_text "$PLANNER_REL" 'never left to a closing-phase flow test' 'or left to a closing-phase flow test'
}

@test "the executor template limits the tests a sub-agent writes" {
  green check_executor_limit
}

@test "red twin: deleting the executor limit clause fails" {
  red check_executor_limit "$PLANNER_REL" 'the tests a sub-agent writes**' 'the tests a sub-agent writes (removed)'
}

@test "the executor template requires linting the sub-agent's own files before it returns" {
  green check_executor_lint
}

@test "red twin: naming the lint command without requiring it fails" {
  red check_executor_lint "$PLANNER_REL" '**The prompt template MUST also require linting the sub-agent'"'"'s own files before it returns**, with' '**The prompt template MUST also name the command that lints a sub-agent'"'"'s own files**:'
}

@test "red twin: making the lint pass condition absolute fails" {
  red check_executor_lint "$PLANNER_REL" 'until lint reports no problem its edit caused, error or warning' 'until lint reports no problem, error or warning'
}

@test "red twin: dropping the lint clause's exit for problems its edit did not cause fails" {
  red check_executor_lint "$PLANNER_REL" ', and a problem its edit did not cause, such as an unresolved import of a file a sibling task has not written yet, goes under `### Findings`, not chased.' '.'
}

@test "planner cuts build phases as vertical slices" {
  green check_vertical_slicing
}

@test "red twin: removing the vertical-slice rule fails" {
  red check_vertical_slicing "$PLANNER_REL" 'Each build phase delivers a behavior end to end.' 'Each build phase does some work.'
}

@test "the Phase order bullet requires the ORCHESTRATOR phase entry form" {
  green check_phase_entry_form
}

@test "red twin: removing the ORCHESTRATOR entry form needle fails" {
  red check_phase_entry_form "$PLANNER_REL" 'Open each phase entry with `**Phase <N>, <title>`' 'Open each phase entry with a phase title'
}

@test "the tdd loop limits new tests to named behaviors and both-condition unit tests" {
  green check_tdd_loop
}

@test "red twin: restoring the one-test-at-a-time loop fails" {
  red check_tdd_loop "$TDD_REL" 'Don'"'"'t anticipate future tests.' 'Don'"'"'t anticipate future tests. One test at a time.'
}

@test "a task doc names only its own flow test, seam tests and both-condition unit tests; other tests go to README follow-ups" {
  green check_task_doc_test_naming
}

@test "red twin: letting a task doc name any test the planner judges worthwhile fails" {
  red check_task_doc_test_naming "$PLANNER_REL" 'goes under `## Follow-ups` in `README.md`, never into a task doc.' 'may go into a task doc.'
}

@test "red twin: dropping how each unit-test condition holds fails" {
  red check_task_doc_test_naming "$PLANNER_REL" ', stating how each condition holds' ''
}

@test "an absence requirement counts as a guard and every case of a multi-case row but a non-guard flow case is asserted in the task's named test" {
  green check_absence_and_cases
}

@test "red twin: making the absence requirement optional fails" {
  red check_absence_and_cases "$PLANNER_REL" 'rendered) counts as a guard' 'rendered) is optional'
}

@test "red twin: an absence test with the value never present fails" {
  red check_absence_and_cases "$PLANNER_REL" ' while the value is present upstream' ''
}

# check_case_split <root>: the planner and the SPEC coverage lens both split a
# compound condition per part and an order-of-checks row per adjacent pair, and
# the lens reads every SPEC section a guard case lives in.
check_case_split() {
  local plan lens
  plan="$(flat "$1/$PLANNER_REL")"
  lens="$(range_of "$1/$AUDIT_REL" '- **SPEC coverage' '- **' | tr '\n' ' ' | tr -s ' ')"
  need "$plan" 'A compound condition is one case per part' || return 1
  need "$plan" 'an order-of-checks row is one case per adjacent pair of checks, asserted by a test whose input passes every earlier check, fails both, and asserts the earlier of the pair refused' || return 1
  need "$lens" '`success_criteria` + `scope_boundaries` + `clarifications.answered`' || return 1
  need "$lens" 'one row per case' || return 1
  need "$lens" 'a compound condition one per part' || return 1
  need "$lens" 'an order-of-checks row one per adjacent pair of checks' || return 1
  need "$lens" 'a guard case with no test a task names below the closing flow' || return 1
  need "$lens" 'an order-of-checks pair with no test that passes every earlier check, fails both, and asserts the earlier of the pair refused' || return 1
  need "$lens" 'a signed or encrypted value (a cookie, a session, a token) with no test sending a forged or edited one' || return 1
}

# check_forged_value <root>: the planner counts refusing a value the app did not
# issue as a guard whose test sends a forged or edited value.
check_forged_value() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" 'A property that makes the app refuse a value it did not issue (a signed or encrypted cookie or session, a signed token) counts as a guard too' || return 1
  need "$text" 'its test sends a forged or edited value and asserts the refusal' || return 1
}

@test "planner counts refusing a forged signed value as a guard with a forged-value test" {
  green check_forged_value
}

@test "red twin: dropping the forged signed value guard fails" {
  red check_forged_value "$PLANNER_REL" 'counts as a guard too: its test sends a forged or edited value and asserts the refusal. ' ''
}

@test "red twin: a signed value test that never forges one fails" {
  red check_forged_value "$PLANNER_REL" 'sends a forged or edited value' 'sends the issued value'
}

@test "red twin: the coverage lens dropping the forged signed value hole fails" {
  red check_case_split "$AUDIT_REL" ' a signed or encrypted value (a cookie, a session, a token) with no test sending a forged or edited one;' ''
}

@test "planner and the SPEC coverage lens split compound conditions and check order into cases" {
  green check_case_split
}

@test "red twin: the coverage lens checking rows instead of cases fails" {
  red check_case_split "$AUDIT_REL" 'one row per case' 'one row per SPEC row'
}

@test "red twin: the planner order-of-checks case not asserting the earlier check refused fails" {
  red check_case_split "$PLANNER_REL" ', fails both, and asserts the earlier of the pair refused' ', fails both'
}

@test "red twin: the coverage lens order-of-checks hole not asserting the earlier check refused fails" {
  red check_case_split "$AUDIT_REL" ', fails both, and asserts the earlier of the pair refused' ', fails both'
}

@test "red twin: the coverage lens skipping scope_boundaries and clarifications.answered fails" {
  red check_case_split "$AUDIT_REL" ' + `scope_boundaries` + `clarifications.answered`' ''
}

@test "red twin: the coverage lens dropping the uncovered guard case hole fails" {
  red check_case_split "$AUDIT_REL" 'a guard case with no test a task names below the closing flow, and ' ''
}

@test "red twin: the planner dropping the compound condition split fails" {
  red check_case_split "$PLANNER_REL" 'A compound condition is one case per part' 'A compound condition is one case'
}

@test "red twin: the planner pinning check order without a both-failing test fails" {
  red check_case_split "$PLANNER_REL" ', asserted by a test whose input passes every earlier check, fails both, and asserts the earlier of the pair refused' ''
}

@test "red twin: asserting only one case of a multi-case row fails" {
  red check_absence_and_cases "$PLANNER_REL" 'Every case a multi-case SPEC row lists is' 'One case a multi-case SPEC row lists is'
}

@test "red twin: leaving a guard case of a multi-case row to the closing flow fails" {
  red check_absence_and_cases "$PLANNER_REL" 'unless it is no guard and the closing flow asserts it' 'unless the closing flow asserts it'
}
