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
# removing the whole check when the brief is merely silent on it. A model
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
  SPEC_AUDIT_REL=".claude/skills/gaia/references/spec/audit.md"
  FIXER_RULE='The task doc, the SPEC and its Required reading decide which is wrong: never change an asserted label, role, message or URL they state to match the code.'
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

# Both plan fixers free to edit code or test are told the requirement sources
# decide which side is wrong.
check_plan_fixers_keep_requirements() {
  local flow_arm named_fixer
  flow_arm="$(joined "$(range_of "$1/$PLANNER_REL" '- **Flow-test arm.**' '- **In-phase arm.**')")"
  need_text 'flow-test arm' "$flow_arm" || return 1
  in_order "$flow_arm" 'Fix the cause in the code or in the test, whichever is wrong,' "$FIXER_RULE" 'The failing tests:' || return 1
  named_fixer="$(joined "$(range_of "$1/$PLANNER_REL" '- **Exit 1, the named fixer.**' '- **Halt.**')")"
  need_text 'named pre-audit fixer' "$named_fixer" || return 1
  in_order "$named_fixer" 'Fix the cause in the code or in the test, whichever is wrong,' "$FIXER_RULE" 'The failures:' || return 1
}

check_merge_hold_on_requirement_conflict() {
  local question
  question="$(joined "$(range_of "$1/$PLANNER_REL" '**The merge question.**' '- **Post-clearance')")"
  need_text 'merge question' "$question" || return 1
  in_order "$question" \
    '- a deviation the summary surfaced needs a decision the human has not given;' \
    'a finding or deviation saying the shipped app differs from the SPEC or its Required reading always does,' \
    'never as a follow-up;' || return 1
}

check_audit_fixer_keeps_requirements() {
  local region
  region="$(joined "$(range_of "$1/$ROUND_REL" '**Fixer dispatch.**' '**Classify the fixer from its file**')")"
  need_text 'audit fixer dispatch prompt' "$region" || return 1
  in_order "$region" \
    'A repair never changes a label, role, message or URL that SPEC or a document its Required reading names states, nor a test'"'"'s assertion of one:' \
    'that entry returns disputed with a reason that starts `conflicts with requirement:` and quotes the requirement line.' || return 1
}

check_spec_audit_keeps_scaffold_checks() {
  local lens
  lens="$(grep -F -- '- **Factual grounding (id prefix `FG`).**' "$1/$SPEC_AUDIT_REL")"
  need_text 'factual grounding lens' "$lens" || return 1
  in_order "$lens" \
    'Where the SPEC or a document its Required reading names conflicts with a check the scaffold ships' \
    'propose only the narrowest repair that satisfies what they state, keeping the rest of the check' \
    'a check they are silent on is never removed.' || return 1
}

# ---------- tests ----------

@test "plan fixers let the requirement sources decide whether code or test is wrong" {
  green check_plan_fixers_keep_requirements
}

@test "red twin: a flow-test arm or named fixer free to rewrite a stated label fails" {
  red check_plan_fixers_keep_requirements "$PLANNER_REL" "and say which under ### Deviations from plan. $FIXER_RULE The failing tests:" 'and say which under ### Deviations from plan. The failing tests:'
  red check_plan_fixers_keep_requirements "$PLANNER_REL" "and say which under ### Deviations from plan. $FIXER_RULE The failures:" 'and say which under ### Deviations from plan. The failures:'
}

@test "the merge question holds on a shipped conflict with the SPEC or its Required reading" {
  green check_merge_hold_on_requirement_conflict
}

@test "red twin: a merge question that reads a SPEC conflict as a follow-up fails" {
  red check_merge_hold_on_requirement_conflict "$PLANNER_REL" ' a finding or deviation saying the shipped app differs from the SPEC or its Required reading always does, and the summary lists it as a decision to make, never as a follow-up;' ''
}

@test "the audit fixer disputes a repair that changes stated wording or its test" {
  green check_audit_fixer_keeps_requirements
}

@test "red twin: an audit fixer free to change stated wording fails" {
  red check_audit_fixer_keeps_requirements "$ROUND_REL" 'A repair never changes a label, role, message or URL' 'A repair may change a label, role, message or URL'
  red check_audit_fixer_keeps_requirements "$ROUND_REL" 'that entry returns disputed with a reason that starts `conflicts with requirement:`' 'that entry is fixed anyway'
}

@test "the spec audit keeps a scaffold check a brief is silent on" {
  green check_spec_audit_keeps_scaffold_checks
}

@test "red twin: a spec audit free to drop a whole scaffold check fails" {
  red check_spec_audit_keeps_scaffold_checks "$SPEC_AUDIT_REL" 'propose only the narrowest repair that satisfies what they state, keeping the rest of the check' 'propose removing the check'
  red check_spec_audit_keeps_scaffold_checks "$SPEC_AUDIT_REL" '; a check they are silent on is never removed.' '.'
}
