#!/usr/bin/env bats
#
# Doc-conformance suite for the testing-trophy rewrite set.
#
# The doctrine moved from "every check at the lowest layer that can prove it"
# to the testing trophy. This suite pins that move so the pyramid wording
# cannot slide back in a later edit:
#
#   - every rewritten file is free of its named old phrase and carries a
#     positive pin (the trophy axiom on the layering page, a link to the page
#     on a pointing reference, the planner's acceptance wording, the index
#     entry);
#   - every line kept on purpose is still present;
#   - the layering page holds the whole rule and the pointing references link
#     it without copying its axiom.
#
# Every presence and absence check matches on the whitespace-normalized file
# text, because several of these files are hard-wrapped and a correct rewrite
# can wrap a multi-word needle. Every check is a function taking the file it
# reads, so each red twin runs the same function on a mutated copy and proves
# it can fail. Adding a row to a table is the only edit a later change needs.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LAYERING='wiki/decisions/Test Layering.md'
  AXIOM='the route layer is the default home for behavior'
  LINK='wiki/decisions/Test Layering.md'
  PLANNER_PIN='Name the behavior the task delivers and the acceptance test that owns it'
  TESTS_REACT='apps/web/.claude/skills/tdd-react/references/tests-react.md'

  # file|old phrase (must be absent)|positive pin (must be present)
  REWRITE_ROWS=(
    "$LAYERING|Every check lives at the lowest layer that can prove it|$AXIOM"
    "$LAYERING|demoting a test to the lowest layer that shows its property|$AXIOM"
    "$LAYERING|the emergent tests|$AXIOM"
    "$TESTS_REACT|lowest layer that can verify the behavior|$LINK"
    "$TESTS_REACT"'|one `.test()` per behavior|'"$LINK"
    "$TESTS_REACT|renders nothing for a null amount|$LINK"
    "$TESTS_REACT"'|still need a `.test()`|'"$LINK"
    ".claude/skills/tdd/SKILL.md|List the behaviors to test|$LINK"
    ".claude/skills/tdd/SKILL.md|For each remaining behavior|$LINK"
    ".claude/skills/tdd/SKILL.md|One test at a time|$LINK"
    'apps/web/.claude/rules/storybook.md|a `.test()` per GAIA behavior|'"$LINK"
    '.claude/agents/worthiness-evaluator.md|need a `.test()` each|'"$LINK"
    ".claude/agents/overlap-evaluator.md|route test or a unit test already asserts|$LINK"
    ".claude/agents/overlap-evaluator.md|Four kinds|$LINK"
    ".claude/skills/gaia/references/overlap-pass.md|so the pass also moves a test down to that layer|$LINK"
    ".claude/skills/gaia/references/plan/planner.md|One criterion per guard, refusal, or gate|$PLANNER_PIN"
    ".claude/skills/gaia/references/spec/spec-template.md|case tables belong to the lowest layer|$LINK"
    ".claude/skills/gaia/references/spec/self-review.md|case tables belong to the lowest layer|$LINK"
    ".claude/skills/gaia/references/spec/self-review.md|leaving the cases to the lowest layer|$LINK"
    "wiki/index.md|each check sits at the lowest layer that proves it|both unit-test conditions"
  )

  # file|needle (must stay present)
  KEPT_ROWS=(
    "$LAYERING|Browser time is the expensive layer in three ways"
    "$LAYERING|The route surface is the lowest layer that takes a request in process"
    "$LAYERING|one test per user flow"
    "$LAYERING|A rule function returns the wrong answer"
    "$LAYERING|A plan carries one real-server check per guarded route module"
    ".claude/skills/tdd/SKILL.md|Good tests are integration-style"
    ".claude/skills/tdd/SKILL.md|You can't test everything."
    ".claude/skills/tdd/SKILL.md|Author the test against a stub of the implementation symbol."
    ".claude/skills/tdd/SKILL.md|Every proposed DELETE requires human confirmation and renders its evidence INLINE."
    'wiki/decisions/Worthiness Audit.md|**proposes** verdicts and **edits no files**; a human acts on every proposal.'
    ".claude/agents/overlap-evaluator.md|The journey floor: never propose demoting or dropping a flow's only browser journey."
    ".claude/agents/worthiness-evaluator.md|state of the controls a user drives. A suite of tests for an interactive"
    "$TESTS_REACT|For an interactive component, the tests assert a keyboard path"
    ".claude/skills/gaia/references/spec/clarify-prompts.md|One flow per critical user path."
    'wiki/decisions/Route Browser UATs By The Capability That Needs A Browser.md|one UAT per transition, status or role rule keeps traceability'
    "apps/web/.claude/rules/playwright.md|One journey per user flow"
    '.claude/skills/tdd/references/tests-shell.md|one `.bats` file per script under test'
    ".claude/skills/tdd/references/tests-shell.md|One test, one change, repeat."
    'wiki/concepts/Code Review Audit Agent.md|records `Outcome: did not run` and lets the run continue'
  )

  # Pages that point at the layering page and must not copy its axiom.
  POINTING_REFS=(
    ".claude/skills/tdd/SKILL.md"
    "$TESTS_REACT"
    "apps/web/.claude/rules/storybook.md"
  )

  # Needles the layering page itself must carry.
  RULE_NEEDLES=(
    "$AXIOM"
    "both unit-test conditions"
    "the integration layer cannot cover its cases cheaply"
    "the logic is important or likely to fail"
    "One test per user-observable behavior"
    "a parameterized table is one test"
    "nothing the type checker or lint already proves"
    "from the closed list under [[#When a test needs a real browser]]"
  )
}

# ---------- helpers ----------

# Whitespace-normalized text of file $1.
norm() { tr '\n' ' ' <"$1" | tr -s ' '; }

# True when the normalized text of $1 contains $2.
has() { norm "$1" | grep -qF -- "$2"; }

# Copy $1 to $2 with every occurrence of $3 deleted (normalized text).
drop_needle() {
  local text
  text="$(norm "$1")"
  printf '%s\n' "${text//"$3"/}" >"$2"
}

# Copy $1 to $2 and append $3 on its own line.
append_line() {
  cp "$1" "$2"
  printf '\n%s\n' "$3" >>"$2"
}

# check_rewrite_row <file> <old phrase> <positive pin>
check_rewrite_row() {
  local file="$1" old="$2" pin="$3"
  has "$file" "$old" && { echo "old phrase present: $old"; return 1; }
  has "$file" "$pin" || { echo "pin missing: $pin"; return 1; }
  return 0
}

# check_kept_row <file> <needle>
check_kept_row() {
  has "$1" "$2" || { echo "kept needle missing: $2"; return 1; }
  return 0
}

# check_rule_page <file>: the layering page holds the whole rule.
check_rule_page() {
  local file="$1" needle
  for needle in "${RULE_NEEDLES[@]}"; do
    has "$file" "$needle" || { echo "missing: $needle"; return 1; }
  done
  has "$file" 'Every check lives at the lowest layer that can prove it' &&
    { echo "pyramid axiom still present"; return 1; }
  return 0
}

# check_pointing_reference <file>: links the page, never copies its axiom.
check_pointing_reference() {
  local file="$1"
  has "$file" "$LINK" || { echo "link missing"; return 1; }
  has "$file" "$AXIOM" && { echo "copies the axiom"; return 1; }
  return 0
}

# Run check function $1 over every table row (split on '|'); report the first
# failing row. An empty table fails: a per-row claim over nothing proves nothing.
each_row() {
  local fn="$1" row file a b out
  shift
  [ "$#" -gt 0 ] || { echo "empty table"; return 1; }
  for row in "$@"; do
    IFS='|' read -r file a b <<<"$row"
    out="$("$fn" "$REPO_ROOT/$file" "$a" ${b:+"$b"})" || { echo "$file: $out"; return 1; }
  done
  return 0
}

# ---------- current files ----------

@test "every rewritten file is free of its old phrase and carries its pin" {
  each_row check_rewrite_row "${REWRITE_ROWS[@]}"
}

@test "every kept line is still present" {
  each_row check_kept_row "${KEPT_ROWS[@]}"
}

@test "the layering page holds the trophy rule and the pointing references link it without copying it" {
  check_rule_page "$REPO_ROOT/$LAYERING"
  local ref
  for ref in "${POINTING_REFS[@]}"; do
    check_pointing_reference "$REPO_ROOT/$ref" || { echo "$ref"; return 1; }
  done
}

# ---------- red twins ----------

@test "red twin: restoring any old phrase fails its row" {
  local row file old pin copy="$BATS_TEST_TMPDIR/copy.md"
  for row in "${REWRITE_ROWS[@]}"; do
    IFS='|' read -r file old pin <<<"$row"
    append_line "$REPO_ROOT/$file" "$copy" "$old"
    check_rewrite_row "$copy" "$old" "$pin" >/dev/null &&
      { echo "did not go red: $file: $old"; return 1; }
  done
  true
}

@test "red twin: removing a pin fails its row" {
  local row file old pin copy="$BATS_TEST_TMPDIR/copy.md"
  for row in "${REWRITE_ROWS[@]}"; do
    IFS='|' read -r file old pin <<<"$row"
    drop_needle "$REPO_ROOT/$file" "$copy" "$pin"
    check_rewrite_row "$copy" "$old" "$pin" >/dev/null &&
      { echo "did not go red: $file: $pin"; return 1; }
  done
  true
}

@test "red twin: removing any kept needle fails its row" {
  local row file needle copy="$BATS_TEST_TMPDIR/copy.md"
  for row in "${KEPT_ROWS[@]}"; do
    IFS='|' read -r file needle <<<"$row"
    drop_needle "$REPO_ROOT/$file" "$copy" "$needle"
    check_kept_row "$copy" "$needle" >/dev/null &&
      { echo "did not go red: $file: $needle"; return 1; }
  done
  true
}

@test "red twin: a layering page missing any rule needle fails" {
  local needle copy="$BATS_TEST_TMPDIR/copy.md"
  for needle in "${RULE_NEEDLES[@]}"; do
    drop_needle "$REPO_ROOT/$LAYERING" "$copy" "$needle"
    check_rule_page "$copy" >/dev/null &&
      { echo "did not go red: $needle"; return 1; }
  done
  true
}

@test "red twin: a layering page that regains the pyramid axiom fails" {
  local copy="$BATS_TEST_TMPDIR/copy.md"
  append_line "$REPO_ROOT/$LAYERING" "$copy" 'Every check lives at the lowest layer that can prove it'
  check_rule_page "$copy" >/dev/null && return 1
  true
}

@test "red twin: a pointing reference that copies the axiom fails" {
  local copy="$BATS_TEST_TMPDIR/copy.md"
  append_line "$REPO_ROOT/$TESTS_REACT" "$copy" "$AXIOM"
  check_pointing_reference "$copy" >/dev/null && return 1
  true
}

@test "red twin: a pointing reference without the link fails" {
  local ref copy="$BATS_TEST_TMPDIR/copy.md"
  for ref in "${POINTING_REFS[@]}"; do
    drop_needle "$REPO_ROOT/$ref" "$copy" "$LINK"
    check_pointing_reference "$copy" >/dev/null &&
      { echo "did not go red: $ref"; return 1; }
  done
  true
}
