#!/usr/bin/env bats
#
# Doc-conformance suite for the CHANGELOG gate's timing.
#
# The maintainer-only CHANGELOG gate in wiki/concepts/PR Merge Workflow.md
# runs at two moments: the entry lands before the first audit dispatch, and
# the merge-time check only verifies it. This suite pins:
#
#   - the pre-dispatch section names the gate, inside a maintainer-only block;
#   - the gate section names both moments and the fix_count re-read trigger;
#   - the merge step and pr-merge.md point at the verify-only check.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  MERGE_WORKFLOW="$REPO_ROOT/wiki/concepts/PR Merge Workflow.md"
  PR_MERGE_RULE="$REPO_ROOT/.claude/rules/pr-merge.md"
  H_PRE='#### Before the first dispatch'
  H_GATE='## CHANGELOG gate (maintainer-only)'
  H_MERGE='### 4. Merge'
  PRE_LITERAL='[[#CHANGELOG gate (maintainer-only)]]'
}

# ---------- helpers ----------

# section_text <file> <heading prefix>: the heading line and its body, up to
# the next heading of the same or a higher level.
section_text() {
  awk -v h="$2" '
    function level(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    !on && index($0, h) == 1 { on = 1; start = level($0); print; next }
    on && /^#+ / && level($0) <= start { exit }
    on { print }' "$1"
}

# marked_only <file> <heading> <literal>: <literal> appears in the section,
# and only inside a maintainer-only block.
marked_only() {
  local section
  section=$(section_text "$1" "$2")
  grep -qF -- "$3" <<<"$section" || return 1
  awk '
    /<!-- gaia:maintainer-only:start -->/ { skip = 1; next }
    /<!-- gaia:maintainer-only:end -->/ { skip = 0; next }
    !skip { print }' <<<"$section" | grep -qF -- "$3" && return 1
  true
}

# gate_names_both_moments <file>
gate_names_both_moments() {
  local section
  section=$(section_text "$1" "$H_GATE")
  grep -qF -- '**Before the first audit dispatch: decide and land.**' <<<"$section" || return 1
  grep -qF -- '**At merge: verify only.**' <<<"$section" || return 1
  grep -qF -- '`fix_count` above 0' <<<"$section"
}

# merge_step_verifies <file>
merge_step_verifies() {
  section_text "$1" "$H_MERGE" | grep -qF -- 'Run the **CHANGELOG gate**'"'"'s merge check'
}

# rule_lands_before_audit <file>
rule_lands_before_audit() {
  grep -qF -- 'before the first audit dispatch' "$1" || return 1
  grep -qF -- 'only when the entry is missing or false' "$1"
}

# ---------- pre-dispatch placement ----------

@test "the pre-dispatch section names the gate inside a maintainer-only block" {
  marked_only "$MERGE_WORKFLOW" "$H_PRE" "$PRE_LITERAL"
}

# ---------- the gate's two moments ----------

@test "the gate section names both moments and the fix_count trigger" {
  gate_names_both_moments "$MERGE_WORKFLOW"
}

@test "the merge step runs the verify-only check" {
  merge_step_verifies "$MERGE_WORKFLOW"
}

# ---------- the rule ----------

@test "pr-merge.md lands the entry before the audit and corrects it only when wrong" {
  rule_lands_before_audit "$PR_MERGE_RULE"
}

