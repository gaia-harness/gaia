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
  PAGE_PIN='Route is the default home for behavior because'
  DOCTRINE='.claude/doctrine/testing.md'
  LINK='wiki/decisions/Test Layering.md'
  PLANNER_PIN='Name the behavior the task delivers and its `- Test:` lines'
  TESTS_REACT='apps/web/.claude/skills/tdd-react/references/tests-react.md'

  # file|old phrase (must be absent)|positive pin (must be present)
  REWRITE_ROWS=(
    "$LAYERING|Every check lives at the lowest layer that can prove it|$PAGE_PIN"
    "$LAYERING|demoting a test to the lowest layer that shows its property|$PAGE_PIN"
    "$LAYERING|the emergent tests|$PAGE_PIN"
    "$TESTS_REACT|lowest layer that can verify the behavior|$DOCTRINE"
    "$TESTS_REACT"'|one `.test()` per behavior|'"$DOCTRINE"
    "$TESTS_REACT|renders nothing for a null amount|$DOCTRINE"
    "$TESTS_REACT"'|still need a `.test()`|'"$DOCTRINE"
    ".claude/skills/tdd/SKILL.md|List the behaviors to test|$DOCTRINE"
    ".claude/skills/tdd/SKILL.md|For each remaining behavior|$DOCTRINE"
    ".claude/skills/tdd/SKILL.md|One test at a time|$DOCTRINE"
    'apps/web/.claude/rules/storybook.md|a `.test()` per GAIA behavior|'"$DOCTRINE"
    '.claude/agents/worthiness-evaluator.md|need a `.test()` each|'"$LINK"
    ".claude/agents/overlap-evaluator.md|route test or a unit test already asserts|$LINK"
    ".claude/agents/overlap-evaluator.md|Four kinds|$LINK"
    ".claude/skills/gaia/references/overlap-pass.md|so the pass also moves a test down to that layer|$LINK"
    ".claude/skills/gaia/references/plan/planner.md|One criterion per guard, refusal, or gate|$PLANNER_PIN"
    ".claude/skills/gaia/references/plan/planner.md|when no flow test already covers it|$PLANNER_PIN"
    ".claude/skills/gaia/references/plan/planner.md|covering the happy path and each error path the build has|$PLANNER_PIN"
    ".claude/skills/gaia/references/spec/spec-template.md|case tables belong to the lowest layer|$DOCTRINE"
    # #3484: the keyboard and focus mandate covers only code that handles keys
    # or moves focus; native controls in DOM order are the browser's.
    '.claude/agents/worthiness-evaluator.md|For an **interactive** component, the `.test()` units together|whose own code handles keys or moves focus'
    ".claude/agents/worthiness-evaluator.md|A suite of tests for an interactive component|Native controls in DOM order (inputs, selects and buttons in a plain form)"
    '.claude/agents/worthiness-evaluator.md|For an **interactive** component, the `.test()` units together|`required` attribute the browser renders from a literal prop'
    "apps/web/.claude/rules/storybook.md|For an interactive component the tests cover a keyboard path|$DOCTRINE"
    "$TESTS_REACT|For an interactive component, the tests assert a keyboard path|$DOCTRINE"
    "apps/web/.claude/skills/new-component/SKILL.md|for an interactive component assert a keyboard path|$DOCTRINE"
    "$DOCTRINE|For an interactive component the tests cover a keyboard path|Native controls in DOM order get no keyboard or focus test"
    "$DOCTRINE|For an interactive component the tests cover a keyboard path|Code in the app's tree that handles keys or moves focus"
    ".claude/skills/gaia/references/spec/self-review.md|case tables belong to the lowest layer|$DOCTRINE"
    ".claude/skills/gaia/references/spec/self-review.md|leaving the cases to the lowest layer|$DOCTRINE"
    "wiki/index.md|each check sits at the lowest layer that proves it|the reasons behind the testing trophy"
  )

  # file|needle (must stay present)
  KEPT_ROWS=(
    "$LAYERING|Browser time is the expensive layer in three ways"
    "$LAYERING|the route surface is the lowest layer that takes a request in process"
    "$DOCTRINE|Write one flow test per critical flow"
    "$LAYERING|A rule function returns the wrong answer"
    "$DOCTRINE|Give each guarded route module one real-server check"
    ".claude/skills/tdd/SKILL.md|Good tests are integration-style"
    ".claude/skills/tdd/SKILL.md|You can't test everything."
    ".claude/skills/tdd/SKILL.md|Author the test against a stub of the implementation symbol."
    'wiki/decisions/Worthiness Audit.md|**proposes** verdicts and **edits no files**; a human acts on every proposal.'
    ".claude/agents/overlap-evaluator.md|The journey floor: never propose demoting or dropping a flow's only browser journey."
    ".claude/agents/worthiness-evaluator.md|An axe pass on a render does not supply that signal"
    "$TESTS_REACT|An axe pass says nothing about focus order, keyboard operation"
    ".claude/skills/gaia/references/spec/clarify-prompts.md|One flow per critical user path."
    "apps/web/.claude/rules/playwright.md|One journey per user flow"
    '.claude/skills/tdd/references/tests-shell.md|one `.bats` file per script under test'
    ".claude/skills/tdd/references/tests-shell.md|One test, one change, repeat."
    'wiki/concepts/Code Review Audit Agent.md|records `Outcome: did not run` and lets the run continue'
  )

  # Pages that point at the layering page and must not copy its axiom.
  POINTING_REFS=(
    ".claude/skills/tdd/SKILL.md|$DOCTRINE"
    "$TESTS_REACT|$DOCTRINE"
    "apps/web/.claude/rules/storybook.md|$DOCTRINE"
  )

  # Needles the doctrine file must carry: it owns the rules the layering page keeps only the reasons for.
  RULE_NEEDLES=(
    'route layer is the default home for behavior'
    'Unit-test conditions'
    'The integration layer cannot cover its cases cheaply'
    'The logic is important'
    'at most one test per user-observable behavior'
    'a case table is one test'
    'what the type checker or lint already proves'
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

# check_rule_page <file>: the doctrine file holds the whole rule.
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
  local file="$1" link="${2:-$LINK}"
  has "$file" "$link" || { echo "link missing"; return 1; }
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

@test "the doctrine holds the trophy rule and the pointing references link the layering page without copying it" {
  check_rule_page "$REPO_ROOT/$DOCTRINE"
  local row ref link
  for row in "${POINTING_REFS[@]}"; do
    IFS='|' read -r ref link <<<"$row"
    check_pointing_reference "$REPO_ROOT/$ref" "$link" || { echo "$ref"; return 1; }
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

@test "red twin: a doctrine missing any rule needle fails" {
  local needle copy="$BATS_TEST_TMPDIR/copy.md"
  for needle in "${RULE_NEEDLES[@]}"; do
    drop_needle "$REPO_ROOT/$DOCTRINE" "$copy" "$needle"
    check_rule_page "$copy" >/dev/null &&
      { echo "did not go red: $needle"; return 1; }
  done
  true
}

@test "red twin: a doctrine that regains the pyramid axiom fails" {
  local copy="$BATS_TEST_TMPDIR/copy.md"
  append_line "$REPO_ROOT/$DOCTRINE" "$copy" 'Every check lives at the lowest layer that can prove it'
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
  local row ref link copy="$BATS_TEST_TMPDIR/copy.md"
  for row in "${POINTING_REFS[@]}"; do
    IFS='|' read -r ref link <<<"$row"
    drop_needle "$REPO_ROOT/$ref" "$copy" "$link"
    check_pointing_reference "$copy" "$link" >/dev/null &&
      { echo "did not go red: $ref"; return 1; }
  done
  true
}
