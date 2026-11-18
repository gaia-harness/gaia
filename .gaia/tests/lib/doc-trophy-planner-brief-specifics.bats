#!/usr/bin/env bats
#
# Doc-conformance suite for stated specifics in a plan: a role, accessible name,
# exact wording or attribute the SPEC, an audit directive or the SPEC's Required
# reading states, one a task doc names for its builder included, gets an
# existing or planned test asserting it, so a later edit cannot change it unseen.
# Pins the doctrine's stated-literal rules and the planner's read of the
# documents a SPEC's Required reading names.
#
# Method: every check takes a root directory and reads the files from it; each
# red twin mutates one substring of a scratch copy, proves the copy changed,
# and runs the same check against it. Matching is on whitespace-normalized text.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  DOCTRINE_REL=".claude/doctrine/testing.md"
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

# mutated_tree <relpath> <old> <new>: copy the two files into a scratch tree
# (TREE), replace the first fixed-string <old> in <relpath> with <new>, and
# prove the copy changed.
mutated_tree() {
  local rel="$1" old="$2" new="$3" file content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for file in "$PLANNER_REL" "$DOCTRINE_REL"; do
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
  local text doctrine
  text="$(flat "$1/$PLANNER_REL")"
  doctrine="$(flat "$1/$DOCTRINE_REL")"
  need "$doctrine" 'Assert a role, accessible name, exact wording or attribute a stated requirement gives as that stated literal' || return 1
  need "$doctrine" 'One existing or planned test satisfies it at any layer, a flow test only for a role or accessible name; one story or route test may hold all of a page'"'"'s stated literals, a loader-data heading'"'"'s route test aside (`## Served HTML`); never add a flow for one.' || return 1
  need "$doctrine" 'A stated literal a task doc names for its builder counts as asserted only once a test, or a flow task doc'"'"'s list of the literals it asserts, names it.' || return 1
  need "$doctrine" 'Never assert through an import of the app'"'"'s own string' || return 1
  need "$text" 'Read the documents its `## Required reading` names too, for any role, accessible name or exact wording they state;' || return 1
}

# ---------- tests ----------

@test "the doctrine and planner: a stated role, name or wording gets a test, and a stated literal a task doc names counts only once a test names it" {
  green check_acceptance_clause
  red check_acceptance_clause "$DOCTRINE_REL" 'Assert a role, accessible name, exact wording or attribute a stated requirement gives' 'Note a role, accessible name, exact wording or attribute a stated requirement gives'
  red check_acceptance_clause "$DOCTRINE_REL" 'exact wording or attribute a stated requirement' 'exact wording a stated requirement'
  red check_acceptance_clause "$DOCTRINE_REL" 'a flow test only for a role or accessible name' 'a flow test included'
  red check_acceptance_clause "$DOCTRINE_REL" 'counts as asserted only once a test' 'counts as asserted once the builder'
  red check_acceptance_clause "$DOCTRINE_REL" 'one story or route test may hold all' 'each specific needs its own test, not all'
  red check_acceptance_clause "$DOCTRINE_REL" 'never add a flow for one' 'add a flow for each'
  red check_acceptance_clause "$DOCTRINE_REL" 'Never assert through an import of the app' 'Assert through an import of the app'
  red check_acceptance_clause "$PLANNER_REL" 'Read the documents its `## Required reading` names too' 'Skip the documents its `## Required reading` names'
}
