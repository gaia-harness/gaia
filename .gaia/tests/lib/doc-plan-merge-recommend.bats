#!/usr/bin/env bats
#
# Doc-conformance suite for a plan build's merge question and its close after
# a new-session audit continue.
#
# Part A: the plan's merge question recommends merging when the merge is
# ready and holding only for a named reason (the orchestrator template, the
# merge question); user-questions.md no longer lists a plan build's merge among the
# never-Recommended options and states the situational merge rule.
# Part B: a plan build resumed into the PR Merge Workflow (the checkpoint's
# continuation prompt, or any other route) returns to the plan's
# ORCHESTRATOR.md, so its merge question and post-clearance block run before
# the merge; the grant hook tells the main thread to print that prompt.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPLATE_REL=".claude/skills/gaia/references/plan/orchestrator-template.md"
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

green() {
  run "$1" "$REPO_ROOT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

# ---------- checks ----------

# Part A: the plan's merge question is situational.
check_plan_merge_question() {
  local summary question
  summary="$(range_of "$1/$TEMPLATE_REL" '## Final summary' '## Post-clearance')"
  need_text 'Final summary' "$summary" || return 1
  lacks "$summary" '`Hold the merge` (Recommended) or `Merge it`' || return 1
  question="$(range_of "$1/$TEMPLATE_REL" '**The merge question.**' '## Post-clearance')"
  need_text 'merge question' "$question" || return 1
  has "$question" 'Recommend `Merge it` when the merge is ready' || return 1
  has "$question" 'Recommend `Hold the merge` only when one of these holds, and its description then says' || return 1
  has "$question" '`bash .gaia/scripts/pr-wait-merge.sh --pr <N> --until-green --attempts 20`' || return 1
  has "$question" 'names `no required check is declared`, which has none to hold on' || return 1
  has "$question" '`TIMEOUT` (required checks still pending after the wait)' || return 1
  lacks "$question" 'is still pending (`gh pr checks' || return 1
  lacks "$question" '`I did it`' || return 1
  lacks "$question" '(HALTED)' || return 1
  has "$question" 'nor is a phase halt, however it was answered: a halted phase commits only after its gate passes' || return 1
  has "$question" 'it needs no stated reason' || return 1
  has "$question" 'says in plain words what is blocking the merge and what the user can do about it' || return 1
  has "$question" 'never quoting this list'"'"'s wording, a verdict token such as `CHECK_FAILED`, or a `PROGRESS.md` label' || return 1
  has "$question" 'Residuals the human accepted at the audit checkpoint are no hold reason' || return 1
}

# Part A: the rule no longer forbids recommending a plan build's merge, and
# states the situational merge rule.
check_rule_merge() {
  local never
  never="$(grep -F -- '- **Never recommend widening your own authority.**' "$1/$RULE_REL")"
  need_text 'never-Recommended bullet' "$never" || return 1
  lacks "$never" "merging a plan build's pull request" || return 1
  has "$never" 'merging over audit residuals the residual question asks about while no human has answered it' || return 1
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
  has "$checkpoint" 'Resume the plan for PR #<N> on branch <branch>, working root <RESOLVED_ROOT>, run folder <RUN_FOLDER>: read <PLAN_DIR>/ORCHESTRATOR.md, reconnect per its resume detection without asking its confirmation gate, then continue from its `gaia:orchestrator-step code-audit` block by dispatching the next audit unit.' || return 1
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

@test "the rule drops a plan build's merge from the never-Recommended list and states the merge rule" {
  green check_rule_merge
}

@test "a plan build resumed into the merge workflow returns to its ORCHESTRATOR.md" {
  green check_workflow_plan_route
}

@test "the grant hook routes a plan build's new-session prompt to the plan" {
  green check_hook_plan_prompt
}

