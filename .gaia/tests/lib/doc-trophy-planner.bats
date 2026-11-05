#!/usr/bin/env bats
#
# Doc-conformance suite for the planner's testing-trophy behavior.
#
# .claude/skills/gaia/references/plan/planner.md tells a planner to name
# behaviors and the acceptance tests that own them, to drive a guard red at the
# layer where the user sees the refusal, to cut phases as vertical slices, and
# to bound the tests a task executor writes. The tdd skill's loop carries the
# matching limit. This suite pins that text and the ORCHESTRATOR phase-entry
# form the phase-ownership check reads.
#
# Method: every check takes a root directory and reads the planner reference or
# the tdd skill from it; each red twin mutates one substring of a scratch copy,
# proves the copy changed, and runs the same check against it. Presence and
# absence match on whitespace-normalized text.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  TDD_REL=".claude/skills/tdd/SKILL.md"
  LIMIT_CLAUSE='**The prompt template MUST also limit the tests a sub-agent writes**'
  RED_CLAUSE='**The prompt template MUST also order a new test'"'"'s RED**'
}

# ---------- helpers ----------

# flat <file>: the file's text with newlines and runs of spaces collapsed.
flat() { tr '\n' ' ' <"$1" | tr -s ' '; }

# has <text> <needle>: the fixed needle occurs in the text.
has() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

need() {
  has "$1" "$2" || { printf 'missing: %s\n' "$2" >&2; return 1; }
}

lacks() {
  has "$1" "$2" && { printf 'present, must be absent: %s\n' "$2" >&2; return 1; }
  return 0
}

# range_of <file> <start fixed string> <end fixed string>: the lines from the
# first start match up to, not including, the first end match after it.
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1"
}

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

check_acceptance_text() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" 'Name the behavior the task delivers and the acceptance test that owns it' || return 1
  need "$text" 'not a list of tests per function' || return 1
  need "$text" 'at the layer where the user sees the refusal' || return 1
  need "$text" '.claude/rules/guards-must-fail.md' || return 1
  lacks "$text" 'One criterion per guard, refusal, or gate' || return 1
}

check_executor_limit() {
  local range
  range="$(range_of "$1/$PLANNER_REL" '**Sub-agent invocation:**' '**Orchestrator-owned git flow.**' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$range" ] || { printf 'executor template range not found\n' >&2; return 1; }
  need "$range" "$LIMIT_CLAUSE" || return 1
  need "$range" 'a new test only for a behavior or acceptance test its task doc names' || return 1
  need "$range" "$RED_CLAUSE" || return 1
  local before_red="${range%%"$RED_CLAUSE"*}"
  has "$before_red" "$LIMIT_CLAUSE" || { printf 'limit clause does not precede the RED clause\n' >&2; return 1; }
}

check_vertical_slicing() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" 'owns the acceptance test that proves it' || return 1
  need "$text" '- Phase <N>: Infrastructure: <reason>' || return 1
  need "$text" 'whatever the surface' || return 1
}

check_phase_entry_form() {
  local bullet
  bullet="$(range_of "$1/$PLANNER_REL" '- **Phase order**' '- **Worthiness step.**' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$bullet" ] || { printf 'Phase order bullet not found\n' >&2; return 1; }
  need "$bullet" '**Phase <N>, <title>' || return 1
}

check_tdd_loop() {
  local text
  text="$(flat "$1/$TDD_REL")"
  need "$text" 'Write a new test only for those behaviors and their acceptance tests' || return 1
  need "$text" 'both unit-test conditions' || return 1
  lacks "$text" 'For each remaining behavior' || return 1
  lacks "$text" 'One test at a time' || return 1
}

# ---------- tests ----------

@test "planner names behaviors and acceptance tests and drops the per-guard criterion line" {
  green check_acceptance_text
}

@test "red twin: restoring the per-guard criterion line fails" {
  red check_acceptance_text "$PLANNER_REL" 'not a list of tests per function' 'not a list of tests per function. One criterion per guard, refusal, or gate'
}

@test "the executor template limits the tests a sub-agent writes, ahead of the RED order" {
  green check_executor_limit
}

@test "red twin: deleting the executor limit clause fails" {
  red check_executor_limit "$PLANNER_REL" 'the tests a sub-agent writes**' 'the tests a sub-agent writes (removed)'
}

@test "red twin: moving the executor limit after the RED clause fails" {
  red check_executor_limit "$PLANNER_REL" 'MUST also limit the tests' 'MUST also order a new test'"'"'s RED** (moved) **The prompt template MUST also limit the tests'
}

@test "planner cuts vertical slices and names the infrastructure marker" {
  green check_vertical_slicing
}

@test "red twin: removing the infrastructure marker literal fails" {
  red check_vertical_slicing "$PLANNER_REL" '- Phase <N>: Infrastructure: <reason>' '- Phase <N>: Plumbing: <reason>'
}

@test "the Phase order bullet requires the ORCHESTRATOR phase entry form" {
  green check_phase_entry_form
}

@test "red twin: removing the ORCHESTRATOR entry form needle fails" {
  red check_phase_entry_form "$PLANNER_REL" 'Open each phase entry with `**Phase <N>, <title>`' 'Open each phase entry with a phase title'
}

@test "the tdd loop limits new tests to named behaviors and both-condition unit tests" {
  green check_tdd_loop
}

@test "red twin: restoring the one-test-at-a-time loop fails" {
  red check_tdd_loop "$TDD_REL" 'Don'"'"'t anticipate future tests.' 'Don'"'"'t anticipate future tests. One test at a time.'
}
