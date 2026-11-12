#!/usr/bin/env bats
#
# Doc-conformance suite for the clauses that keep a build faithful to its
# requirement sources: the task doc, the SPEC and the documents its Required
# reading names (the brief), and the checks the scaffold ships.
#
# Without them a fixer facing a failing test may rewrite the test to match the
# code, so a label, role or message the brief states ships changed; the merge
# question reads a known conflict with the SPEC as a follow-up and recommends
# merging; and the spec audit resolves a conflict with a scaffold check by
# removing the whole check when the brief is merely silent on it. And once the
# audit fixer disputes a guard for lack of a requirement, the main thread may
# put its own question recommending that guard and add it outside the fix
# round, so the fixer's requirement rule never applies. A model
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
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  ROUND_REL="wiki/concepts/Audit Round Procedure.md"
  MERGE_REL="wiki/concepts/PR Merge Workflow.md"
  LENS_PREAMBLE_REL=".claude/skills/gaia/references/spec/lens-dispatch.md"
  FIXER_RULE='The task doc and, when {PLAN_DIR}/README.md names a Source SPEC, that SPEC and the documents its Required reading names decide which is wrong: never change an asserted label, role, message or URL they state to match the code.'
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

# Every plan fixer free to edit code or test is told the requirement sources
# decide which side is wrong.
check_plan_fixers_keep_requirements() {
  local flow_arm named_fixer in_phase_arm outside_arm
  in_phase_arm="$(joined "$(range_of "$1/$PLANNER_REL" '- **In-phase arm.**' '- **Outside arm.**')")"
  need_text 'in-phase arm' "$in_phase_arm" || return 1
  in_order "$in_phase_arm" 'update the test when this phase changed the asserted behavior on purpose,' "$FIXER_RULE" 'The failing tests:' || return 1
  outside_arm="$(joined "$(range_of "$1/$PLANNER_REL" '- **Outside arm.**' '- **Re-run the gate.**')")"
  need_text 'outside arm' "$outside_arm" || return 1
  in_order "$outside_arm" 'update the test when this phase changed the asserted behavior on purpose,' "$FIXER_RULE" 'The failing tests:' || return 1
  flow_arm="$(joined "$(range_of "$1/$PLANNER_REL" '- **Flow-test arm.**' '- **In-phase arm.**')")"
  need_text 'flow-test arm' "$flow_arm" || return 1
  in_order "$flow_arm" 'Fix the cause in the code or in the test, whichever is wrong,' "$FIXER_RULE" 'The failing tests:' || return 1
  named_fixer="$(joined "$(range_of "$1/$PLANNER_REL" '- **Exit 1, the named fixer.**' '- **Halt.**')")"
  need_text 'named pre-audit fixer' "$named_fixer" || return 1
  in_order "$named_fixer" 'Fix the cause in the code or in the test, whichever is wrong,' "$FIXER_RULE" 'The failures:' || return 1
}

check_merge_hold_on_requirement_conflict() {
  local question summary
  question="$(joined "$(range_of "$1/$PLANNER_REL" '**The merge question.**' '- **Post-clearance')")"
  need_text 'merge question' "$question" || return 1
  in_order "$question" \
    '- a deviation the summary surfaced needs a decision the human has not given;' \
    'a finding or deviation saying the shipped app differs from the SPEC or its Required reading needs that decision unless the human already accepted it at the audit checkpoint;' || return 1
  summary="$(joined "$(range_of "$1/$PLANNER_REL" '- **Final summary.**' '**The merge question.**')")"
  need_text 'final summary' "$summary" || return 1
  in_order "$summary" \
    'a finding or deviation saying the shipped app differs from the SPEC or its Required reading is listed as a decision to make, never as a follow-up,' \
    'unless the human accepted it at the audit checkpoint.' || return 1
}

check_audit_fixer_keeps_requirements() {
  local region
  region="$(joined "$(range_of "$1/$ROUND_REL" '**Fixer dispatch.**' '**Classify the fixer from its file**')")"
  need_text 'audit fixer dispatch prompt' "$region" || return 1
  in_order "$region" \
    'A repair never moves a label, role, message or URL away from what that SPEC or a document its Required reading names states, nor changes a test'"'"'s assertion of one to match the code;' \
    'repair the code to the stated value instead;' \
    'only when the code cannot be brought to it, return the entry disputed with a reason that starts `conflicts with requirement:` and quotes the requirement line.' || return 1
}

check_spec_audit_keeps_scaffold_checks() {
  local lens
  lens="$(grep -F -- 'conflicts with a check the scaffold ships' "$1/$LENS_PREAMBLE_REL")"
  need_text 'shared lens preamble scaffold clause' "$lens" || return 1
  in_order "$lens" \
    'Where the SPEC or a document its Required reading names conflicts with a check the scaffold ships' \
    'propose only the narrowest repair that satisfies what they state, keeping the rest of the check' \
    'an unset one may fall back to a strong per-process random value the app logs at startup' \
    'while a set value under 32 characters is still refused.' \
    'A check they are silent on is never removed.' || return 1
}

# A guard the fixer disputed reaches the human only through the checkpoint,
# and only the fix round edits a file a finding names.
check_disputes_stay_with_the_fixer() {
  local disputes veto hands_off
  disputes="$(joined "$(range_of "$1/$MERGE_REL" '**Disputed fix entries.**' '**The merge report.**')")"
  need_text 'disputed fix entries paragraph' "$disputes" || return 1
  in_order "$disputes" \
    'goes to the human only through the branch checkpoint' \
    'the main thread asks no question of its own about it.' \
    'recommends adding it only when it quotes the SPEC row or Required-reading line that requires it.' || return 1
  veto="$(joined "$(range_of "$1/$MERGE_REL" '**The waiver table and the veto.**' 'After a veto, rewrite')")"
  need_text 'veto paragraph' "$veto" || return 1
  in_order "$veto" \
    'Only the loop'"'"'s fixer or a human writes that fix:' \
    'the main thread may commit the fixer'"'"'s own uncommitted edits on a human'"'"'s answer at a `needs-human` stop,' \
    'but never writes a new edit to satisfy a veto, by hand or through an agent outside the fix round.' || return 1
  hands_off="$(grep -F -- '- **During the loop the main thread never hand-edits a file a finding names.**' "$1/$ROUND_REL")"
  need_text 'hands-off bullet' "$hands_off" || return 1
  in_order "$hands_off" 'Nor does the unit, and neither dispatches any agent but the round'"'"'s fixer to edit one.' || return 1
}

# ---------- tests ----------

@test "plan fixers let the requirement sources decide whether code or test is wrong" {
  green check_plan_fixers_keep_requirements
}

@test "red twin: an in-phase or outside arm free to rewrite a stated label fails" {
  red check_plan_fixers_keep_requirements "$PLANNER_REL" "$FIXER_RULE If the cause is not in this task's files, edit nothing and say so under ### Findings. The failing tests:" "If the cause is not in this task's files, edit nothing and say so under ### Findings. The failing tests:"
  red check_plan_fixers_keep_requirements "$PLANNER_REL" "$FIXER_RULE If the cause is not in this task's files, edit nothing and say so under ### Findings, on a line" "If the cause is not in this task's files, edit nothing and say so under ### Findings, on a line"
}

@test "red twin: a flow-test arm or named fixer free to rewrite a stated label fails" {
  red check_plan_fixers_keep_requirements "$PLANNER_REL" "and say which under ### Deviations from plan. $FIXER_RULE The failing tests:" 'and say which under ### Deviations from plan. The failing tests:'
  red check_plan_fixers_keep_requirements "$PLANNER_REL" "and say which under ### Deviations from plan. $FIXER_RULE The failures:" 'and say which under ### Deviations from plan. The failures:'
}

@test "the merge question holds on a shipped conflict with the SPEC or its Required reading" {
  green check_merge_hold_on_requirement_conflict
}

@test "red twin: a merge question that reads a SPEC conflict as a follow-up fails" {
  red check_merge_hold_on_requirement_conflict "$PLANNER_REL" ' a finding or deviation saying the shipped app differs from the SPEC or its Required reading needs that decision unless the human already accepted it at the audit checkpoint;' ''
  red check_merge_hold_on_requirement_conflict "$PLANNER_REL" '; a finding or deviation saying the shipped app differs from the SPEC or its Required reading is listed as a decision to make, never as a follow-up, unless the human accepted it at the audit checkpoint.' '.'
}

@test "the audit fixer disputes a repair that changes stated wording or its test" {
  green check_audit_fixer_keeps_requirements
}

@test "red twin: an audit fixer free to change stated wording fails" {
  red check_audit_fixer_keeps_requirements "$ROUND_REL" 'A repair never moves a label, role, message or URL' 'A repair may move a label, role, message or URL'
  red check_audit_fixer_keeps_requirements "$ROUND_REL" 'return the entry disputed with a reason that starts `conflicts with requirement:`' 'return the entry fixed anyway'
}

@test "the spec audit keeps a scaffold check a brief is silent on" {
  green check_spec_audit_keeps_scaffold_checks
}

@test "red twin: a spec audit free to drop a whole scaffold check fails" {
  red check_spec_audit_keeps_scaffold_checks "$LENS_PREAMBLE_REL" 'propose only the narrowest repair that satisfies what they state, keeping the rest of the check' 'propose removing the check'
  red check_spec_audit_keeps_scaffold_checks "$LENS_PREAMBLE_REL" ' A check they are silent on is never removed.' ''
  red check_spec_audit_keeps_scaffold_checks "$LENS_PREAMBLE_REL" 'while a set value under 32 characters is still refused.' 'and a set value of any length is accepted.'
}

@test "a disputed guard reaches the human only through the checkpoint and only the fix round edits" {
  green check_disputes_stay_with_the_fixer
}

@test "red twin: a main thread free to ask about or recommend a disputed guard fails" {
  red check_disputes_stay_with_the_fixer "$MERGE_REL" 'the main thread asks no question of its own about it.' 'the main thread may ask its own question about it.'
  red check_disputes_stay_with_the_fixer "$MERGE_REL" 'recommends adding it only when it quotes the SPEC row' 'recommends adding it whenever it names the SPEC row'
}

@test "red twin: a veto satisfied by a one-off agent's edit, or one that bars committing the fixer's edits, fails" {
  red check_disputes_stay_with_the_fixer "$MERGE_REL" 'but never writes a new edit to satisfy a veto, by hand or through an agent outside the fix round.' 'or dispatches a one-off agent to make the fix.'
  red check_disputes_stay_with_the_fixer "$MERGE_REL" "the main thread may commit the fixer's own uncommitted edits on a human's answer at a \`needs-human\` stop, but never writes" "the main thread never commits the fixer's edits and never writes"
  red check_disputes_stay_with_the_fixer "$ROUND_REL" ", and neither dispatches any agent but the round's fixer to edit one." '.'
}
