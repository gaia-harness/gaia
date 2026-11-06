#!/usr/bin/env bats
#
# Doc-conformance suite for the RED order in the plan executor's prompt
# template.
#
# .claude/skills/gaia/references/plan/planner.md tells a planner what the task
# executor's prompt must say about a new test's failing-first run (RED). The
# commit's RED gate binds that run to the test's executable body, so an
# executor whose lint fix changes that body after its RED loses it and the phase
# commit is refused after the executor has already returned. This suite pins
# the order that prevents it, split across two dispatches (a test author that
# stubs, lints and runs RED, then an implementer), the orchestrator's split
# block between them, the test review that checks the tests before any
# implementer runs, the stub's final signature (type-aware lint on the test
# reads it), the edited-after-RED report, the tdd skill section the template
# points at, and that section's own stub-first order.
#
# Method: every check takes a root directory and reads the Sub-agent
# invocation bullet or the tdd skill's honest-RED section; each red twin
# mutates one clause of a scratch
# copy, proves the copy changed, and runs the same check against it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  TDD_REL=".claude/skills/tdd/SKILL.md"
  REVIEW_REL=".claude/skills/gaia/references/plan/test-review.md"
  TDD_HEADING='#### Authoring an honest RED on the deterministic surface'
  DISPATCH_CLAUSES='**The prompt template MUST also carry the two dispatch clauses below, and a dispatch sends only the one for its kind**'
}

# ---------- helpers ----------

# range_of <file> <start fixed string> <end fixed string>: the lines from the
# first start match up to, not including, the first end match after it.
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1"
}

trim_lines() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# in_order <text> <anchor>...: every anchor appears in <text>, each after the
# one before it.
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

invocation_range() { range_of "$1/$PLANNER_REL" '**Sub-agent invocation:**' '**Orchestrator-owned git flow.**' | trim_lines; }

# mutated_tree <relpath> <old> <new>: copy planner.md, the tdd skill and the
# test review page into a
# scratch tree (TREE), replace the first fixed-string <old> in <relpath> with
# <new>, and prove the copy changed.
mutated_tree() {
  local rel="$1" old="$2" new="$3" file content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for file in "$PLANNER_REL" "$TDD_REL" "$REVIEW_REL"; do
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

# mutate_again <relpath> <old> <new>: a second fixed-string replacement in the
# scratch tree mutated_tree built, for a twin one replacement cannot express.
mutate_again() {
  local content mutated
  content="$(cat "$TREE/$1"; printf x)"
  mutated="${content/"$2"/"$3"}"
  [ "$mutated" != "$content" ] || { printf 'second mutation left %s unchanged: %s\n' "$1" "$2" >&2; return 1; }
  printf '%s' "${mutated%x}" > "$TREE/$1"
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

check_red_order() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    '**The prompt template MUST also name the command that lints a sub-agent'"'"'s own files**' \
    "$DISPATCH_CLAUSES" \
    '**Test-author clause.**' \
    'For each new exported symbol a test imports, write a stub under its final name' \
    'Lint the tests and stubs with the lint command above' \
    'then typecheck with `pnpm -C <package dir> typecheck` in any wave, in place of the typecheck above' \
    'Fix by hand every lint finding and type error in a file you wrote, re-running both until clean' \
    'a TS2307 on a `+types` module may be a sibling'"'"'s typegen mid-write: re-run once; if it persists, it is yours to fix' \
    'Then run the RED command for each test file and return' \
    'Write no implementation.' \
    '**Implementer clause.**' \
    'Replace the stubs with the implementation and lint it' || return 1
}

check_stub_wrong_value() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    '**Test-author clause.**' \
    'The stub returns a wrong value, so the RED fails on an assertion' \
    'it throws only when the symbol has no return value to get wrong' || return 1
}

# A guessed seeded email makes the RED a setup lookup throw, not an assertion,
# and the later fix to the email voids that RED; an identity two tests both
# create collides on a shared database.
check_seed_identity() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    '**Test-author clause.**' \
    'from the seed source the plan names, or the project'"'"'s seed file' \
    'never guess one' \
    'Make each identity a test creates in its Given' \
    'unique to that test' \
    '**Implementer clause.**' || return 1
}

check_edit_after_red_reported() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    '**Implementer clause.**' \
    'Never edit the executable body of a test in the task doc'"'"'s `New tests:` files' \
    'at any layer, Vitest or Playwright, whether or not the RED ledger tracks it' \
    'any such edit voids its RED' \
    'never set aside implementation to record one' \
    'Leave a test you judge wrong as it is' \
    'report the needed edit (file, test name, what changed) under `### Deviations from plan`' \
    'The one exception is a phase gate retry'"'"'s `floor` line: change only the call the floor counts, its receiver or arguments' \
    'Add no test and no other call, even one an assertion would read; add, remove or change no assertion' \
    'report the edit under `### Deviations from plan` (file:line, before -> after)' || return 1
}

# The implementer writes no test of its own: the test author's tests are the
# only ones with a RED, so any other new test would reach the phase commit
# with none.
check_implementer_writes_no_test() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    '**Implementer clause.**' \
    'Write no new test: a test you judge worth adding goes under `### Findings`' || return 1
}

# A test author stubs only in its own task's files; a stub in a sibling's file
# is the planning error the decomposition audit owns.
check_stub_ownership() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    '**Test-author clause.**' \
    'Put a stub only in a file this task declares' \
    '`decomposition-audit.md`, the dependency-soundness lens' || return 1
  grep -qF -- '**Decomposition & dependency soundness' "$1/.claude/skills/gaia/references/plan/decomposition-audit.md" \
    || { printf 'decomposition-audit.md has no dependency-soundness lens\n' >&2; return 1; }
}

# The orchestrator's test-first split: test authors, the check, one retry,
# then implementers, with a no-test task held until the check passes.
check_split_block() {
  local block
  block="$(range_of "$1/$PLANNER_REL" '<!-- gaia:orchestrator-step red-split -->' '**Phase gate retry.**' | trim_lines)"
  need_text 'red-split block' "$block" || return 1
  in_order "$block" \
    '**Test authors.**' \
    'Dispatch a test author for every splitting task in the wave, in parallel' \
    '**Check.** Once every test author has returned' \
    'bash .gaia/scripts/red-ledger/red-pending.sh --root <RESOLVED_ROOT>' \
    'Exit 0 goes to the test review block below' \
    'Exit 2 halts under Stop conditions' \
    'A file no task names halts.' \
    '## Phase N, <title> (RED RETRY 1)' \
    'dispatch a fresh test author for each owning task only' \
    'A second exit 1 appends `## Phase N, <title> (HALTED)` with `Reason: no recorded RED`' \
    '**Implementers.**' \
    'Once the test review passes, dispatch an implementer for every task in the wave, split or not' \
    'A task with no test waits for this step' || return 1
}

check_stub_signature() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    '**Test-author clause.**' \
    'under its final name and with its final signature' \
    'a Promise-returning function is stubbed async' \
    'type-aware lint on the test reads the signature' \
    'run the RED command' || return 1
}

check_tdd_stub_signature() {
  local range
  range="$(range_of "$1/$TDD_REL" "$TDD_HEADING" '**Never break working production code' | trim_lines)"
  need_text 'tdd honest-RED section' "$range" || return 1
  in_order "$range" \
    'under its final name and with its final signature' \
    'a Promise-returning function is stubbed async' \
    'type-aware lint on the test reads the signature' \
    'returning a wrong value' || return 1
}

check_points_at_tdd_section() {
  local range heading
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    "$DISPATCH_CLAUSES" \
    "\`$TDD_REL\`, \`$TDD_HEADING\`)" || return 1
  heading="$(grep -Fx -- "$TDD_HEADING" "$1/$TDD_REL")"
  need_text "tdd skill heading $TDD_HEADING" "$heading" || return 1
}

check_tdd_stub_first() {
  local range
  range="$(range_of "$1/$TDD_REL" "$TDD_HEADING" '**Never break working production code' | trim_lines)"
  need_text 'tdd honest-RED section' "$range" || return 1
  in_order "$range" \
    'write a stub of each new exported symbol the test imports, under its final name' \
    'returning a wrong value' \
    'throwing only when the symbol has no return value to get wrong' \
    'Write the test against the stub' \
    'lint both' \
    'run it' \
    'Then write the implementation' \
    'Never point the test at a module file that does not exist yet' \
    'no RED is recorded' || return 1
}

# ---------- tests ----------

@test "the test author stubs, lints and runs RED with no implementation; the implementer comes after" {
  green check_red_order
}

@test "red twin: a RED run placed before the lint step fails" {
  red check_red_order "$PLANNER_REL" \
    'Lint the tests and stubs with the lint command above, then typecheck' \
    'Run the RED command, then lint the tests and stubs with the lint command above, then typecheck'
}

@test "red twin: a test author that typechecks after its RED fails" {
  mutated_tree "$PLANNER_REL" 'Then run the RED command for each test file and return.' 'Return.' || return 1
  mutate_again "$PLANNER_REL" \
    'Lint the tests and stubs with the lint command above, then typecheck' \
    'Lint the tests and stubs with the lint command above. Then run the RED command for each test file and return, then typecheck' || return 1
  run check_red_order "$TREE"
  [ "$status" -ne 0 ] || { printf 'check_red_order still passed with the RED before the typecheck\n' >&2; return 1; }
  [ -n "$output" ]
}

@test "red twin: a test author that typechecks with tsc alone fails" {
  red check_red_order "$PLANNER_REL" \
    'then typecheck with `pnpm -C <package dir> typecheck` in any wave' \
    'then typecheck with `pnpm -C <package dir> exec tsc --noEmit` in any wave'
}

@test "red twin: a test author whose typecheck depends on the wave size fails" {
  red check_red_order "$PLANNER_REL" \
    '`pnpm -C <package dir> typecheck` in any wave, in place' \
    '`pnpm -C <package dir> typecheck` in a wave of one task, in place'
}

@test "red twin: an unbounded re-run on a sibling's typegen race fails" {
  red check_red_order "$PLANNER_REL" \
    'mid-write: re-run once; if it persists, it is yours to fix' \
    'mid-write: re-run until it clears'
}

@test "red twin: a dropped stub step fails" {
  red check_red_order "$PLANNER_REL" \
    'For each new exported symbol a test imports, write a stub under its final name' \
    'Write the tests'
}

@test "red twin: a test author allowed to write implementation fails" {
  red check_red_order "$PLANNER_REL" \
    'Write no implementation.' \
    'Then write the implementation.'
}

@test "the implementer writes no new test and routes one it wants to Findings" {
  green check_implementer_writes_no_test
}

@test "red twin: an implementer allowed to add a test fails" {
  red check_implementer_writes_no_test "$PLANNER_REL" \
    'Write no new test: a test you judge worth adding goes under `### Findings`' \
    'Add any test you judge worth adding'
}

@test "a test author stubs only in its own task's files, pointing at the dependency lens" {
  green check_stub_ownership
}

@test "red twin: a test author free to stub in any file fails" {
  red check_stub_ownership "$PLANNER_REL" \
    'Put a stub only in a file this task declares' \
    'Put a stub wherever the symbol belongs'
}

@test "the split block runs test authors, the check, one retry, then every implementer" {
  green check_split_block
}

@test "red twin: a split block without the retry fails" {
  red check_split_block "$PLANNER_REL" \
    '## Phase N, <title> (RED RETRY 1)' \
    '## Phase N, <title> (HALTED)'
}

@test "red twin: a split block that dispatches no-test tasks before the check fails" {
  red check_split_block "$PLANNER_REL" \
    'A task with no test waits for this step' \
    'A task with no test runs alongside the test authors'
}

@test "the stub returns a wrong value and throws only without one" {
  green check_stub_wrong_value
}

@test "red twin: a stub allowed to throw by default fails" {
  red check_stub_wrong_value "$PLANNER_REL" \
    'it throws only when the symbol has no return value to get wrong' \
    'it may throw instead'
}

@test "the test author takes seeded identities from the seed source and never guesses one" {
  green check_seed_identity
}

@test "red twin: a test author free to guess a seeded identity fails" {
  red check_seed_identity "$PLANNER_REL" \
    'never guess one' \
    'guess when unsure'
}

@test "red twin: a test author free to reuse a created identity across tests fails" {
  red check_seed_identity "$PLANNER_REL" \
    'unique to that test' \
    'shared freely'
}

@test "a RED is never faked after a test edit, and the edit is reported under Deviations from plan" {
  green check_edit_after_red_reported
}

@test "red twin: an edited-after-RED report routed to Findings fails" {
  red check_edit_after_red_reported "$PLANNER_REL" \
    'what changed) under `### Deviations from plan`' \
    'what changed) under `### Findings`'
}

@test "red twin: an implementer clause that guards only the RED ledger's tests fails" {
  red check_edit_after_red_reported "$PLANNER_REL" \
    'at any layer, Vitest or Playwright, whether or not the RED ledger tracks it' \
    'for a test the RED ledger tracks'
}

@test "red twin: a floor exception that reaches past the one counted call fails" {
  red check_edit_after_red_reported "$PLANNER_REL" \
    'change only the call the floor counts, its receiver or arguments' \
    'change the test as the floor needs'
}

@test "red twin: a floor exception that lets an assertion change fails" {
  red check_edit_after_red_reported "$PLANNER_REL" \
    'add, remove or change no assertion' \
    'change an assertion only as the floor needs'
}

@test "red twin: a floor exception edit not reported under Deviations fails" {
  red check_edit_after_red_reported "$PLANNER_REL" \
    'report the edit under `### Deviations from plan` (file:line, before -> after)' \
    'report the edit under `### Findings`'
}

@test "red twin: an implementer clause that lets a wrong test be edited fails" {
  red check_edit_after_red_reported "$PLANNER_REL" \
    'Leave a test you judge wrong as it is' \
    'Fix a test you judge wrong'
}

@test "the executor template stubs each symbol with its final signature, async included" {
  green check_stub_signature
}

@test "red twin: an executor stub with only its final name fails" {
  red check_stub_signature "$PLANNER_REL" \
    'under its final name and with its final signature' \
    'under its final name'
}

@test "red twin: an executor stub that may stay sync fails" {
  red check_stub_signature "$PLANNER_REL" \
    'a Promise-returning function is stubbed async' \
    'any function may be stubbed sync'
}

@test "the tdd skill stubs each symbol with its final signature, async included" {
  green check_tdd_stub_signature
}

@test "red twin: a tdd stub with only its final name fails" {
  red check_tdd_stub_signature "$TDD_REL" \
    'under its final name and with its final signature' \
    'under its final name'
}

@test "the template points at the tdd skill's honest-RED section, which exists" {
  green check_points_at_tdd_section
}

@test "the tdd skill's honest RED writes a wrong-value stub first, then the test, lint, RED, implementation" {
  green check_tdd_stub_first
}

@test "red twin: a tdd section that tests a missing symbol instead of a stub fails" {
  red check_tdd_stub_first "$TDD_REL" \
    'write a stub of each new exported symbol the test imports, under its final name' \
    'point the test at a symbol that does not exist yet'
}

@test "red twin: a tdd section without the missing-module warning fails" {
  red check_tdd_stub_first "$TDD_REL" \
    'Never point the test at a module file that does not exist yet' \
    'Avoid'
}

@test "red twin: a renamed tdd skill heading fails" {
  red check_points_at_tdd_section "$TDD_REL" \
    "$TDD_HEADING" \
    '#### Authoring a RED'
}

# The test review between the RED check and the implementers: the planner's
# block points at the page, and the page dispatches a pinned Sonnet reviewer,
# guards the verdict file, fixes once through the test authors, re-proves the
# REDs, and halts on a defect after that fix.
check_test_review() {
  local block page
  block="$(range_of "$1/$PLANNER_REL" '<!-- gaia:orchestrator-step test-review -->' '**Phase gate retry.**' | trim_lines)"
  need_text 'test-review block' "$block" || return 1
  in_order "$block" \
    'After the test-first split'"'"'s RED check passes and before its implementers' \
    '.claude/skills/gaia/references/plan/test-review.md' || return 1
  page="$(cat "$1/$REVIEW_REL" 2>/dev/null)"
  need_text 'test review page' "$page" || return 1
  in_order "$page" \
    '## Round 1' \
    'Agent(subagent_type: "general-purpose", model: "sonnet")' \
    'bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file' \
    'Every entry `ok`: go to step 4 of the test-first split block' \
    '## A defect' \
    'Reason: test review defect after one fix' \
    '## Phase N, <title> (TEST REVIEW 1)' \
    '**Re-dispatch the owning test authors only**' \
    'bash .gaia/scripts/red-ledger/red-pending.sh --root <RESOLVED_ROOT>' \
    'Reason: no recorded RED after test review' \
    '## Round 2' \
    '## A no-op review' \
    'Reason: test review produced no verdict file' \
    'This departs from the general inline ending' \
    '## The prompt template' \
    'and can a correct implementation pass it?' \
    'No citation, no defect' \
    'The four defects:' \
    '**Over-constraint**' \
    '**Under-constraint**' \
    '**Contradiction**' \
    '**Cannot pass**: no correct implementation can satisfy it' \
    'or a Given that looks up a seeded identity or row' \
    'the seed source does not have' \
    'Out of scope:' || return 1
}

@test "the test review sits between the RED check and the implementers, and its page owns the fix round and the halts" {
  green check_test_review
}

@test "red twin: a split block whose implementers do not wait for the test review fails" {
  red check_split_block "$PLANNER_REL" \
    'Once the test review passes, dispatch an implementer' \
    'Dispatch an implementer'
}

@test "red twin: a test review page with no halt after one fix fails" {
  red check_test_review "$REVIEW_REL" \
    'Reason: test review defect after one fix' \
    'Reason: none'
}

@test "red twin: a test review that does not pin the Sonnet reviewer fails" {
  red check_test_review "$REVIEW_REL" \
    'Agent(subagent_type: "general-purpose", model: "sonnet")' \
    'Agent(subagent_type: "general-purpose")'
}

@test "red twin: a test review that skips the RED re-check after the fix fails" {
  red check_test_review "$REVIEW_REL" \
    'bash .gaia/scripts/red-ledger/red-pending.sh --root <RESOLVED_ROOT>' \
    'nothing'
}

@test "red twin: a test review page without the citation rule fails" {
  red check_test_review "$REVIEW_REL" \
    'No citation, no defect' \
    'Use judgment'
}

@test "red twin: a test review without the cannot-pass defect fails" {
  red check_test_review "$REVIEW_REL" \
    '**Cannot pass**: no correct implementation can satisfy it' \
    '**Other**: anything else'
}

@test "red twin: a cannot-pass defect that ignores unseeded Givens fails" {
  red check_test_review "$REVIEW_REL" \
    'or a Given that looks up a seeded identity or row' \
    'or a fixture'
}

@test "red twin: a test review that never asks whether a test can pass fails" {
  red check_test_review "$REVIEW_REL" \
    ', and can a correct implementation pass it?' \
    '?'
}

@test "red twin: a planner without the test review block fails" {
  red check_test_review "$PLANNER_REL" \
    '<!-- gaia:orchestrator-step test-review -->' \
    '<!-- gone -->'
}
