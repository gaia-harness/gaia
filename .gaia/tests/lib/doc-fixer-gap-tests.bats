#!/usr/bin/env bats
#
# Doc-conformance suite for the two fixers that must write the test a gap
# needs, and for the evaluator lenses that flag tests catching nothing.
#
# The worthiness fixer may edit only the files on its editable list. A flow
# verdict's single-request untested error path belongs to a lower layer (a route test or a
# real-server check), so unless the evaluator names that test file and the fix
# step puts it on the list, the fix always ends cannot_fix and the gap ships as
# a residual. A flow test fixed that way keeps its signal, and a `fixed`
# settlement at an unchanged signal routes it residual, so the step judges it
# again instead. The audit round's fixer can add a guard, refusal or
# validation, and unless its prompt says to drive that guard into its failing
# state, the guard merges untested; unless it says a finding's suggested_fix
# is no requirement, the fixer ships a product rule nobody asked for. The
# evaluator's lenses also name three tests that cost without catching
# anything: a static constant checked against its own value, a boundary call
# count as the sole assertion, and one shared error mapping pinned again per
# caller or listed as a gap per caller. A model
# executes these passages, so an edit that drops one clause would ship
# silently. This suite pins each clause.
#
# Method: every check takes a root directory and reads one region; each red
# twin mutates one clause of a scratch copy, proves the copy changed, and runs
# the same check against it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  EVALUATOR_REL=".claude/agents/worthiness-evaluator.md"
  STEP_REL=".claude/skills/gaia/references/worthiness-step.md"
  ROUND_REL="wiki/concepts/Audit Round Procedure.md"
}

# ---------- helpers ----------

# range_of <file> <start> <end>: the lines from the first start match up to,
# not including, the first end match after it.
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1"
}

# joined <text>: the text on one line, so a wrapped sentence matches whole.
joined() {
  printf '%s\n' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '\n' ' '
}

# in_order <text> <anchor>...: every anchor appears, each after the one before.
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

need_text() {
  [ -n "$2" ] || { printf 'region not found: %s\n' "$1" >&2; return 1; }
}

# mutated_tree <rel> <old> <new>: a scratch tree (TREE) holding a copy of <rel>
# with the first fixed-string <old> replaced by <new>, proved changed.
mutated_tree() {
  local rel="$1" content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  mkdir -p "$TREE/$(dirname "$rel")"
  content="$(cat "$REPO_ROOT/$rel"; printf x)"
  mutated="${content/"$2"/"$3"}"
  printf '%s' "${mutated%x}" >"$TREE/$rel"
  if cmp -s "$REPO_ROOT/$rel" "$TREE/$rel"; then
    printf 'mutation left %s unchanged: %s\n' "$rel" "$2" >&2
    return 1
  fi
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

# ---------- checks ----------

check_evaluator_names_test() {
  local region schema
  region="$(joined "$(range_of "$1/$EVALUATOR_REL" '- List every error path the build has' '- When the test asserts something real')")"
  need_text 'evaluator untestedErrorPaths bullet' "$region" || return 1
  in_order "$region" \
    'its fix is a new test there, never an edit to the flow spec.' \
    'Every entry names in `test` the repo-relative test file that owns its gap:' \
    'the test file of that lower layer that already drives the source'"'"'s module, else a new one where that layer'"'"'s tests live;' \
    'for a path only the flow can stage, the flow file.' \
    '`test` never names a source file.' || return 1
  schema="$(grep -F '"untestedErrorPaths":[{' "$1/$EVALUATOR_REL")"
  need_text 'evaluator flow schema' "$schema" || return 1
  in_order "$schema" '"source":"<file:line>"' '"test":"<test file>"' || return 1
}

check_step_editable_list() {
  local region
  region="$(joined "$(range_of "$1/$STEP_REL" '### 3. Fix' '### 4. Judge again once')")"
  need_text 'worthiness Fix step' "$region" || return 1
  in_order "$region" \
    'for a flow test, the `flow` member of its entry in the Evaluate step'"'"'s verdict file' \
    'no edit outside the list.' \
    'The editable list is the listed test files plus each `test` an `untestedErrorPaths` entry names;' \
    'a named path that is not a test file stays off the list.' \
    'confirms every changed path is in the list' \
    'A flow test fixed only through `test` paths keeps its signal, where `fixed` would route it `residual`, so it is left unsettled for the next step.' || return 1
}

check_step_judges_flow_again() {
  local region
  region="$(joined "$(range_of "$1/$STEP_REL" '### 4. Judge again once' '### 5. Delete')")"
  need_text 'worthiness Judge again step' "$region" || return 1
  in_order "$region" \
    'plus each flow test step 3 left unsettled' \
    'the latest verdict at a signal wins, so the new one replaces the stored `fix`.' \
    'as does an unsettled flow test judged `fix` again.' || return 1
}

check_round_fixer_guard_test() {
  local region
  region="$(joined "$(range_of "$1/$ROUND_REL" '**Fixer dispatch.**' '**Classify the fixer from its file**')")"
  need_text 'audit fixer dispatch prompt' "$region" || return 1
  in_order "$region" \
    'rather than widening the repair.' \
    'A repair that adds a guard, refusal or validation also adds a test that drives it into its failing state' \
    'at the layer wiki/decisions/Test Layering.md picks (a new test file is not a new abstraction);' \
    'when no layer can reach the guard, keep the repair and say so in that entry'"'"'s reason.' || return 1
}

check_round_fixer_guard_requirement() {
  local region
  region="$(joined "$(range_of "$1/$ROUND_REL" '**Fixer dispatch.**' '**Classify the fixer from its file**')")"
  need_text 'audit fixer dispatch prompt' "$region" || return 1
  in_order "$region" \
    'A guard, refusal or validation enforces a requirement:' \
    'name it in that entry'"'"'s reason.' \
    'A finding'"'"'s suggested_fix is a proposal, not a requirement:' \
    'is not added, and the entry returns disputed with a reason that starts `needs a requirement:`' \
    'A repair that adds a guard, refusal or validation also adds a test' || return 1
}

check_unrequired_guard_dispute_stays_open() {
  local bullet
  bullet="$(grep -F -- '- If a Minor finding involves an architectural tradeoff' "$1/$ROUND_REL")"
  need_text 'architectural escalation bullet' "$bullet" || return 1
  in_order "$bullet" \
    'it is escalated with documented rationale rather than marked `fix`' \
    'A fix entry the fixer returns disputed with a reason starting `needs a requirement:` stays open: a member that still finds it reports it again next round,' \
    'and the branch checkpoint puts it to the human ([[PR Merge Workflow#The branch checkpoint]]), who files the remainder, accepts it where the checkpoint offers that, or states the rule where the fixer can cite it.' || return 1
}

check_evaluator_lenses() {
  local honesty worthiness gaps
  honesty="$(joined "$(range_of "$1/$EVALUATOR_REL" '### Axis 1: HONESTY' '### Axis 2: WORTHINESS')")"
  need_text 'honesty axis' "$honesty" || return 1
  in_order "$honesty" \
    'checking a static constant against its own value) can never fail' \
    '`toHaveBeenCalled` or a count of requests to a boundary (how many times `GET /me` ran) as the sole assertion' || return 1
  worthiness="$(joined "$(range_of "$1/$EVALUATOR_REL" '### Axis 2: WORTHINESS' '### Worth criteria for a strict test')")"
  need_text 'worthiness axis' "$worthiness" || return 1
  in_order "$worthiness" \
    '**One test per shared mapping.**' \
    'one test of that mapping covers it.' \
    'A test that pins the same mapping again for another caller is redundant' \
    'unless that caller maps differently.' || return 1
  gaps="$(joined "$(range_of "$1/$EVALUATOR_REL" '- List every error path the build has' '- When the test asserts something real')")"
  need_text 'evaluator untestedErrorPaths bullet' "$gaps" || return 1
  in_order "$gaps" \
    'Error paths that share one mapping helper are one entry, cited at the helper, whose `test` is a route test of any one caller, unless a caller maps differently.' || return 1
}

# ---------- tests ----------

@test "the evaluator names the owning lower-layer test file for each untested error path" {
  green check_evaluator_names_test
}

@test "the evaluator check goes red without the test member, its schema field or its source-file ban" {
  red check_evaluator_names_test "$EVALUATOR_REL" 'Every entry names in `test` the' 'Every entry names in `layer` the'
  red check_evaluator_names_test "$EVALUATOR_REL" ',"test":"<test file>"' ''
  red check_evaluator_names_test "$EVALUATOR_REL" '`test` never names a source file.' 'name any file.'
}

@test "the worthiness fixer's editable list takes each test a flow verdict names" {
  green check_step_editable_list
}

@test "the editable-list check goes red without the named tests, the source-file exclusion, the flow member or the unsettled flow test" {
  red check_step_editable_list "$STEP_REL" 'plus each `test` an `untestedErrorPaths` entry names' 'only'
  red check_step_editable_list "$STEP_REL" 'a named path that is not a test file stays off the list' 'any named path joins the list'
  red check_step_editable_list "$STEP_REL" 'the `flow` member of its entry in the Evaluate step'"'"'s verdict file' 'nothing else'
  red check_step_editable_list "$STEP_REL" 'so it is left unsettled for the next step.' 'so it settles fixed.'
}

@test "a flow test fixed only through a lower-layer test is judged again" {
  green check_step_judges_flow_again
}

@test "the judge-again check goes red without the unsettled flow test or its residual ending" {
  red check_step_judges_flow_again "$STEP_REL" 'plus each flow test step 3 left unsettled' 'and nothing else'
  red check_step_judges_flow_again "$STEP_REL" 'as does an unsettled flow test judged `fix` again.' 'and nothing more.'
}

@test "the evaluator flags constant checks, boundary call counts and a shared mapping pinned per caller" {
  green check_evaluator_lenses
}

@test "the evaluator-lens check goes red without any one lens" {
  red check_evaluator_lenses "$EVALUATOR_REL" ', checking a static constant against its own value)' ')'
  red check_evaluator_lenses "$EVALUATOR_REL" ' or a count of requests to a
  boundary (how many times `GET /me` ran)' ''
  red check_evaluator_lenses "$EVALUATOR_REL" '**One test per shared mapping.**' '**Shared mappings.**'
  red check_evaluator_lenses "$EVALUATOR_REL" 'Error paths that share one mapping helper are one entry,' 'Error paths are listed per caller,'
}

@test "the audit fixer must test a guard its repair adds" {
  green check_round_fixer_guard_test
}

@test "the guard-test check goes red without the duty or its escape" {
  red check_round_fixer_guard_test "$ROUND_REL" 'also adds a test that drives it into its failing state' 'needs no test'
  red check_round_fixer_guard_test "$ROUND_REL" 'keep the repair and say so in that entry'"'"'s reason.' 'return it cannot_fix.'
}

@test "the audit fixer adds a guard only for a requirement it names" {
  green check_round_fixer_guard_requirement
}

@test "the guard-requirement check goes red without the requirement, the proposal rule or the dispute" {
  red check_round_fixer_guard_requirement "$ROUND_REL" 'A guard, refusal or validation enforces a requirement:' 'A guard may come from anywhere:'
  red check_round_fixer_guard_requirement "$ROUND_REL" 'suggested_fix is a proposal, not a requirement:' 'suggested_fix is a requirement:'
  red check_round_fixer_guard_requirement "$ROUND_REL" 'the entry returns disputed with a reason that starts `needs a requirement:`' 'the entry is fixed anyway'
}

@test "an unrequired-guard dispute stays open until the checkpoint puts it to the human" {
  green check_unrequired_guard_dispute_stays_open
}

@test "the dispute check goes red without the open entry, the checkpoint or the human's answers" {
  red check_unrequired_guard_dispute_stays_open "$ROUND_REL" 'stays open: a member that still finds it reports it again next round,' 'is dropped,'
  red check_unrequired_guard_dispute_stays_open "$ROUND_REL" 'and the branch checkpoint puts it to the human' 'and the fixer adds it anyway'
  red check_unrequired_guard_dispute_stays_open "$ROUND_REL" 'or states the rule where the fixer can cite it.' 'and nothing else.'
}
