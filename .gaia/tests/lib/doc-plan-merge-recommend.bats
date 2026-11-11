#!/usr/bin/env bats
#
# Doc-conformance suite for a plan build's merge question and its close after
# a new-session audit continue.
#
# Part A: the plan's merge question recommends merging when the merge is
# ready and holding only for a named reason (planner.md, the merge question
# bullet); user-questions.md no longer lists a plan build's merge among the
# never-Recommended options and states the situational merge rule.
# Part B: a plan build resumed into the PR Merge Workflow (the checkpoint's
# continuation prompt, or any other route) returns to the plan's
# ORCHESTRATOR.md, so its merge question and post-clearance block run before
# the merge; the grant hook tells the main thread to print that prompt.
#
# Method: every check takes a root directory and reads one region; each red
# twin mutates one clause of a scratch copy, proves the copy changed, and runs
# the same check against it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  RULE_REL=".claude/rules/user-questions.md"
  WORKFLOW_REL="wiki/concepts/PR Merge Workflow.md"
  HOOK_REL=".claude/hooks/audit-loop-ask-grant.sh"
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

has() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  printf 'missing text: %s\n' "$2" >&2
  return 1
}

lacks() {
  case "$1" in
    *"$2"*) printf 'unexpected text present: %s\n' "$2" >&2; return 1 ;;
  esac
  return 0
}

need_text() {
  [ -n "$2" ] || { printf 'region not found: %s\n' "$1" >&2; return 1; }
}

# mutated_tree <rel> <old> <new>: a scratch copy (TREE) of every file the
# checks read, with the first fixed-string <old> in <rel> replaced by <new>,
# proved changed.
mutated_tree() {
  local rel="$1" content mutated file
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for file in "$PLANNER_REL" "$RULE_REL" "$WORKFLOW_REL" "$HOOK_REL"; do
    mkdir -p "$TREE/$(dirname "$file")"
    cp "$REPO_ROOT/$file" "$TREE/$file"
  done
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

# Part A: the plan's merge question is situational.
check_plan_merge_question() {
  local summary question
  summary="$(range_of "$1/$PLANNER_REL" '- **Final summary.**' '- **Post-clearance')"
  need_text 'Final summary' "$summary" || return 1
  lacks "$summary" '`Hold the merge` (Recommended) or `Merge it`' || return 1
  question="$(range_of "$1/$PLANNER_REL" '**The merge question.**' '- **Post-clearance')"
  need_text 'merge question' "$question" || return 1
  has "$question" 'Recommend `Merge it` when the merge is ready' || return 1
  has "$question" 'Recommend `Hold the merge` only when one of these holds, and name it in that option'"'"'s description' || return 1
  has "$question" '`gh pr checks <N> --required`' || return 1
  has "$question" '`I did it` with `Rerun: passed`' || return 1
  has "$question" 'Residuals the human accepted at the audit checkpoint are no hold reason' || return 1
}

# Part A: the rule no longer forbids recommending a plan build's merge, and
# states the situational merge rule.
check_rule_merge() {
  local never
  never="$(grep -F -- '- **Never recommend widening your own authority.**' "$1/$RULE_REL")"
  need_text 'never-Recommended bullet' "$never" || return 1
  lacks "$never" "merging a plan build's pull request" || return 1
  has "$never" 'merging over audit residuals no human accepted' || return 1
  has "$(cat "$1/$RULE_REL")" 'A merge-or-hold question recommends merging when the merge is ready, and holding only for a reason it names in that option'"'"'s description' || return 1
}

# Part B: the workflow hands a plan build back to its ORCHESTRATOR.md, and the
# continuation prompt for a plan build resumes the plan.
check_workflow_plan_route() {
  local dispatch checkpoint
  dispatch="$(range_of "$1/$WORKFLOW_REL" '## Dispatch the audit loop unit' '**The brief.**')"
  need_text 'dispatch section' "$dispatch" || return 1
  has "$dispatch" "grep -rlx --include=RUNNING 'branch: <branch>' .notebook/" || return 1
  has "$dispatch" 'so the merge question comes before the status posts and the merge' || return 1
  checkpoint="$(range_of "$1/$WORKFLOW_REL" '#### The branch checkpoint' '**An accept buys exactly one closing round**')"
  need_text 'checkpoint section' "$checkpoint" || return 1
  has "$checkpoint" 'Resume the plan for PR #<N> on branch <branch>: read <PLAN_DIR>/ORCHESTRATOR.md and continue from its pre-merge Code Audit Team audit step by dispatching the next audit unit, skipping the resume confirmation gate and every step before the audit.' || return 1
}

# Part B: the grant hook tells the main thread to print the plan's prompt on a
# plan build.
check_hook_plan_prompt() {
  local arm
  arm="$(range_of "$1/$HOOK_REL" '*"in a new session")' ';;')"
  need_text 'new-session arm' "$arm" || return 1
  has "$arm" 'a plan build' || return 1
  has "$arm" 'ORCHESTRATOR.md' || return 1
}

# ---------- tests ----------

@test "the plan's merge question recommends merging when ready and holding only for a named reason" {
  green check_plan_merge_question
}

@test "red twin: a fixed hold-first merge question fails" {
  red check_plan_merge_question "$PLANNER_REL" 'Recommend `Merge it` when the merge is ready' 'Recommend `Hold the merge` always'
}

@test "the rule drops a plan build's merge from the never-Recommended list and states the merge rule" {
  green check_rule_merge
}

@test "red twin: a rule that still never recommends a plan build's merge fails" {
  red check_rule_merge "$RULE_REL" 'merging over audit residuals no human accepted' "merging a plan build's pull request or merging over audit residuals"
}

@test "a plan build resumed into the merge workflow returns to its ORCHESTRATOR.md" {
  green check_workflow_plan_route
}

@test "red twin: a continuation prompt with no plan arm fails" {
  red check_workflow_plan_route "$WORKFLOW_REL" 'Resume the plan for PR #<N>' 'Resume the PR merge workflow for PR #<N>'
}

@test "the grant hook routes a plan build's new-session prompt to the plan" {
  green check_hook_plan_prompt
}

@test "red twin: a hook arm with no plan-build prompt fails" {
  red check_hook_plan_prompt "$HOOK_REL" 'ORCHESTRATOR.md' 'the workflow'
}
