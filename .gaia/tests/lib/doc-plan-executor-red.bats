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
# the order that prevents it (stub, lint, RED, implement), the stub's final
# signature (type-aware lint on the test reads it), the edited-after-RED
# report, the tdd skill section the template points at, and that section's own
# stub-first order.
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
  TDD_HEADING='#### Authoring an honest RED on the deterministic surface'
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

# mutated_tree <relpath> <old> <new>: copy planner.md and the tdd skill into a
# scratch tree (TREE), replace the first fixed-string <old> in <relpath> with
# <new>, and prove the copy changed.
mutated_tree() {
  local rel="$1" old="$2" new="$3" file content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for file in "$PLANNER_REL" "$TDD_REL"; do
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
    '**The prompt template MUST also order a new test'"'"'s RED**' \
    'write the test and a stub of each new exported symbol it imports, under its final name' \
    'lint the test and the stub with the lint command above, fixing every finding by hand' \
    'run the RED command' \
    'only then write the implementation and lint it' || return 1
}

check_stub_wrong_value() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    '**The prompt template MUST also order a new test'"'"'s RED**' \
    'The stub returns a wrong value, so the RED fails on an assertion' \
    'it throws only when the symbol has no return value to get wrong' || return 1
}

check_edit_after_red_reported() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    '**The prompt template MUST also order a new test'"'"'s RED**' \
    'Any edit to the executable body of a new test after its RED voids that RED' \
    'never fakes a RED' \
    'reports the test (file, test name, what changed) under `### Deviations from plan`' \
    'and says that test'"'"'s RED is void' || return 1
}

check_stub_signature() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    '**The prompt template MUST also order a new test'"'"'s RED**' \
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
    '**The prompt template MUST also order a new test'"'"'s RED**' \
    "(\`$TDD_REL\`, \`$TDD_HEADING\`)" || return 1
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

@test "the executor template orders stub, lint, RED, then implementation, after the lint command" {
  green check_red_order
}

@test "red twin: a RED run placed before the lint step fails" {
  red check_red_order "$PLANNER_REL" \
    'lint the test and the stub with the lint command above, fixing every finding by hand' \
    'run the RED command, then lint the test and the stub'
}

@test "red twin: a dropped stub step fails" {
  red check_red_order "$PLANNER_REL" \
    'write the test and a stub of each new exported symbol it imports, under its final name' \
    'write the test'
}

@test "the stub returns a wrong value and throws only without one" {
  green check_stub_wrong_value
}

@test "red twin: a stub allowed to throw by default fails" {
  red check_stub_wrong_value "$PLANNER_REL" \
    'it throws only when the symbol has no return value to get wrong' \
    'it may throw instead'
}

@test "a RED is never faked after a test edit, and the edit is reported under Deviations from plan" {
  green check_edit_after_red_reported
}

@test "red twin: an edited-after-RED report routed to Findings fails" {
  red check_edit_after_red_reported "$PLANNER_REL" \
    'under `### Deviations from plan`' \
    'under `### Findings`'
}

@test "red twin: an edited-after-RED report that keeps its RED fails" {
  red check_edit_after_red_reported "$PLANNER_REL" \
    ' and says that test'"'"'s RED is void' \
    ''
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
