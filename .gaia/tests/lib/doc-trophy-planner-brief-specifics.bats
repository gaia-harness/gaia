#!/usr/bin/env bats
#
# Doc-conformance suite for stated specifics in a plan: a role, accessible name
# or exact wording the SPEC, an audit directive or the SPEC's Required reading
# states gets a test a task names, so a later edit cannot change it unseen.
# Pins the planner's acceptance-criteria clause, its markup-directive clause,
# and the decomposition audit's SPEC coverage lens hole and sources.
#
# Method: every check takes a root directory and reads the files from it; each
# red twin mutates one substring of a scratch copy, proves the copy changed,
# and runs the same check against it. Matching is on whitespace-normalized text.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  AUDIT_REL=".claude/skills/gaia/references/plan/decomposition-audit.md"
}

# ---------- helpers ----------

flat() { tr '\n' ' ' <"$1" | tr -s ' '; }

need() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  printf 'missing: %s\n' "$2" >&2
  return 1
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

# ---------- checks ----------

check_acceptance_clause() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" '**A role, accessible name or exact wording the task delivers is asserted by a test this task names**' || return 1
  need "$text" 'the SPEC, an audit directive or a document the SPEC'"'"'s Required reading names states it' || return 1
  need "$text" 'it never gets a flow of its own' || return 1
  need "$text" 'The test asserts the stated literal, never an import of the app'"'"'s own string' || return 1
  need "$text" 'Read the documents its `## Required reading` names too, for any role, accessible name or exact wording they state.' || return 1
}

check_directive_clause() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" 'a role, accessible name or exact wording it states still gets the test the acceptance-criteria bullet under `## Plan files` requires' || return 1
}

check_coverage_lens() {
  local text
  text="$(flat "$1/$AUDIT_REL")"
  need "$text" 'a role, accessible name or exact wording a task delivers, stated by the SPEC, an entry under `## Plan-time directives` in its `AUDIT.md`' || return 1
  need "$text" 'with no test a task names asserting it, including one the brief or audit states that the SPEC omits' || return 1
  need "$text" 'also `AUDIT.md` beside it and the documents its `## Required reading` names' || return 1
  need "$text" 'a test that asserts stated wording through an import of the app'"'"'s own string counts as no test' || return 1
}

# ---------- tests ----------

@test "planner: a stated role, name or wording gets a test a task names" {
  green check_acceptance_clause
  red check_acceptance_clause "$PLANNER_REL" 'is asserted by a test this task names**' 'is noted in the contract**'
  red check_acceptance_clause "$PLANNER_REL" 'it never gets a flow of its own' 'it gets a flow of its own'
  red check_acceptance_clause "$PLANNER_REL" 'asserts the stated literal, never an import' 'asserts the stated literal or an import'
  red check_acceptance_clause "$PLANNER_REL" 'Read the documents its `## Required reading` names too' 'Skip the documents its `## Required reading` names'
}

@test "planner: a markup directive's stated role or name is never code-only" {
  green check_directive_clause
  red check_directive_clause "$PLANNER_REL" 'still gets the test the acceptance-criteria bullet' 'constrains only the code the acceptance-criteria bullet'
}

@test "coverage lens: flags a stated specific with no test, reading the audit and Required reading" {
  green check_coverage_lens
  red check_coverage_lens "$AUDIT_REL" 'including one the brief or audit states that the SPEC omits' 'when the SPEC carries it'
  red check_coverage_lens "$AUDIT_REL" 'also `AUDIT.md` beside it and the documents its `## Required reading` names' 'nothing else'
  red check_coverage_lens "$AUDIT_REL" 'counts as no test' 'counts as a test'
}
