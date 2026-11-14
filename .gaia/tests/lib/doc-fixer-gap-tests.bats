#!/usr/bin/env bats
#
# Doc-conformance suite for the two fixers that must write the test a gap
# needs, and for the evaluator lenses that flag tests catching nothing.
#
# The worthiness fixer may edit only the files on its editable list, which is
# the listed test files and nothing else: the evaluator keeps no list of
# untested error paths, so no verdict widens it. The audit round's fixer can
# add a guard, refusal or validation, and unless its prompt says to drive that
# guard into its failing state, the guard merges untested; unless it says a
# finding's suggested_fix is no requirement, the fixer ships a product rule
# nobody asked for. The evaluator's lenses also name three tests that cost
# without catching anything: a static constant checked against its own value, a
# boundary call count as the sole assertion, and one shared error mapping
# pinned again per caller. A model
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

check_evaluator_lists_no_error_paths() {
  local region
  region="$(joined "$(range_of "$1/$EVALUATOR_REL" '- Never list an error path no stated requirement names' '- When the test asserts something real')")"
  need_text 'evaluator error-path bullet' "$region" || return 1
  in_order "$region" \
    'and never write a test for one;' \
    'the evaluator keeps no list of untested error paths.' \
    '`.claude/doctrine/testing.md` `## Layers` assigns' || return 1
}

check_step_editable_list() {
  local region
  region="$(joined "$(range_of "$1/$STEP_REL" '### 3. Fix' '### 4. Judge again once')")"
  need_text 'worthiness Fix step' "$region" || return 1
  in_order "$region" \
    'for a flow test, the `flow` member of its entry in the Evaluate step'"'"'s verdict file' \
    'no edit outside the list.' \
    'The editable list is the listed test files.' \
    'confirms every changed path is in the list' || return 1
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
    'A fix entry the fixer returns disputed with a reason starting `needs a requirement:` or `conflicts with requirement:` stays open: a member that still finds it reports it again next round,' \
    'and the branch checkpoint puts it to the human ([[PR Merge Workflow#The branch checkpoint]]), who files the remainder, accepts it where the checkpoint offers that, or states the rule where the fixer can cite it:' || return 1
}

check_evaluator_lenses() {
  local honesty worthiness
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
}

# ---------- tests ----------

@test "the evaluator keeps no list of untested error paths" {
  green check_evaluator_lists_no_error_paths
}

@test "the no-error-path-list check goes red without the ban or the layer pointer" {
  red check_evaluator_lists_no_error_paths "$EVALUATOR_REL" 'the evaluator keeps no list of untested error paths.' 'the evaluator lists them.'
  red check_evaluator_lists_no_error_paths "$EVALUATOR_REL" '`.claude/doctrine/testing.md` `## Layers` assigns' 'the lowest layer assigns'
}

@test "the worthiness fixer's editable list is the listed test files only" {
  green check_step_editable_list
}

@test "the editable-list check goes red without the list rule or the flow member" {
  red check_step_editable_list "$STEP_REL" 'The editable list is the listed test files.' 'The editable list is any file.'
  red check_step_editable_list "$STEP_REL" 'the `flow` member of its entry in the Evaluate step'"'"'s verdict file' 'nothing else'
}

@test "the evaluator flags constant checks, boundary call counts and a shared mapping pinned per caller" {
  green check_evaluator_lenses
}

@test "the evaluator-lens check goes red without any one lens" {
  red check_evaluator_lenses "$EVALUATOR_REL" ', checking a static constant against its own value)' ')'
  red check_evaluator_lenses "$EVALUATOR_REL" ' or a count of requests to a
  boundary (how many times `GET /me` ran)' ''
  red check_evaluator_lenses "$EVALUATOR_REL" '**One test per shared mapping.**' '**Shared mappings.**'
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
  red check_unrequired_guard_dispute_stays_open "$ROUND_REL" 'or states the rule where the fixer can cite it:' 'and nothing else.'
}
