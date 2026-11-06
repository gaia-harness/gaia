#!/usr/bin/env bats
#
# Doc-conformance suite for the planner's rule that a UAT's Given binds the
# harness its test runs under.
#
# planner.md step 2 holds a harness choice that changes a UAT's Given to the
# precondition-divergence rule, step 1 keeps a Given check out of Follow-ups, and the decomposition audit's
# SPEC coverage lens grades a harness that departs from a Given as critical.
# This suite pins that text where each rule lives.
#
# Method: every check takes a root directory and reads the files from it; each
# red twin mutates one substring of a scratch copy, proves the copy changed,
# and runs the same check against it. Matching is on whitespace-normalized
# text.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  AUDIT_REL=".claude/skills/gaia/references/plan/decomposition-audit.md"
  GIVEN_HEAD="**A UAT's Given binds its harness.**"
}

# ---------- helpers ----------

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
# first start match up to, not including, the first end match after it,
# whitespace-normalized onto one line.
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1" | tr '\n' ' ' | tr -s ' '
}

# mutated_tree <relpath> <old> <new>: copy both files into a scratch tree
# (TREE), replace the first fixed-string <old> in <relpath> with <new>, and
# prove the copy changed.
mutated_tree() {
  local rel="$1" old="$2" new="$3" file content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for file in "$PLANNER_REL" "$AUDIT_REL"; do
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

# The paragraph lives in step 2 (README), after the routing ladder, and states
# the rule, its pointer, both outcomes and the Follow-ups ban. It stays generic:
# real-backend Givens are out of its scope, so it names no database.
check_given_paragraph() {
  local step paragraph
  step="$(range_of "$1/$PLANNER_REL" '2.  **`{PLAN_DIR}/README.md`**' '3.  **`{PLAN_DIR}/ORCHESTRATOR.md`**')"
  [ -n "$step" ] || { printf 'planner step 2 not found\n' >&2; return 1; }
  need "$step" "$GIVEN_HEAD" || return 1
  local after_ladder="${step#*"- Story test criterion (<uat_id>):"}"
  has "$after_ladder" "$GIVEN_HEAD" || { printf 'Given paragraph does not follow the routing ladder\n' >&2; return 1; }
  # The paragraph closes step 2, so it runs from its heading to step 3.
  paragraph="$(range_of "$1/$PLANNER_REL" "$GIVEN_HEAD" '3.  **`{PLAN_DIR}/ORCHESTRATOR.md`**')"
  need "$paragraph" 'is a precondition divergence (`.claude/skills/gaia/references/spec/uat-divergence.md`)' || return 1
  need "$paragraph" 'an environment variable, seeded state, a server mode' || return 1
  need "$paragraph" 'Meet the Given as written' || return 1
  need "$paragraph" '`### Logical UAT divergence` with category `precondition`' || return 1
  need "$paragraph" 'Never record an unexercised Given under `## Follow-ups`' || return 1
  lacks "$paragraph" 'database' || return 1
}

check_followups_exclusion() {
  local text
  text="$(tr '\n' ' ' <"$1/$PLANNER_REL" | tr -s ' ')"
  need "$text" 'Any other test worth having goes under `## Follow-ups` in `README.md`, never into a task doc. A check that a UAT'"'"'s own Given holds never goes there (step 2).' || return 1
}

check_coverage_lens() {
  local bullet
  bullet="$(range_of "$1/$AUDIT_REL" '- **SPEC coverage (id prefix `COV`' '## 4.6b. Apply findings')"
  [ -n "$bullet" ] || { printf 'SPEC coverage lens not found\n' >&2; return 1; }
  need "$bullet" 'Compare each UAT'"'"'s Given with what the README'"'"'s interface contracts and task docs set up for its test' || return 1
  need "$bullet" 'a harness, fixture or helper that sets up the precondition differently from the Given' || return 1
  need "$bullet" 'a `## Follow-ups` entry conceding part of a Given goes unexercised' || return 1
  need "$bullet" 'is `critical`' || return 1
}

# ---------- green ----------

@test "planner step 2 holds the Given-binds-harness paragraph after the routing ladder" { green check_given_paragraph; }
@test "planner step 1 keeps a check of a UAT's own Given out of Follow-ups" { green check_followups_exclusion; }
@test "the SPEC coverage lens grades a harness that departs from a Given as critical" { green check_coverage_lens; }

# ---------- red twins ----------

@test "red twin: dropping the paragraph heading fails the paragraph check" {
  red check_given_paragraph "$PLANNER_REL" "$GIVEN_HEAD" '**Harness notes.**'
}

@test "red twin: allowing a Follow-up for an unexercised Given fails the paragraph check" {
  red check_given_paragraph "$PLANNER_REL" 'Never record an unexercised Given under `## Follow-ups`' 'Record an unexercised Given under `## Follow-ups`'
}

@test "red twin: dropping the divergence report route fails the paragraph check" {
  red check_given_paragraph "$PLANNER_REL" '`### Logical UAT divergence` with category `precondition`' 'a note'
}

@test "red twin: a database-specific example fails the paragraph check" {
  red check_given_paragraph "$PLANNER_REL" 'an environment variable, seeded state, a server mode' 'an environment variable, a database file, seeded state, a server mode'
}

@test "red twin: dropping the Follow-ups exclusion fails the step 1 check" {
  red check_followups_exclusion "$PLANNER_REL" ' A check that a UAT'"'"'s own Given holds never goes there (step 2).' ''
}

@test "red twin: dropping the critical grade fails the coverage lens check" {
  red check_coverage_lens "$AUDIT_REL" 'is `critical`' 'is `minor`'
}

@test "red twin: dropping the Follow-ups concession fails the coverage lens check" {
  red check_coverage_lens "$AUDIT_REL" 'a `## Follow-ups` entry conceding part of a Given goes unexercised' 'a gap'
}
