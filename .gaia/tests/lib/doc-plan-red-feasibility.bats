#!/usr/bin/env bats
#
# Doc-conformance suite for the planner's rule that every new test can fail
# on its phase's base.
#
# A case asserting behavior an earlier phase already built passes before its
# phase writes anything, so the test-first split never records its RED and the
# build halts. planner.md step 2 keeps that build in the phase owning the UAT,
# and the decomposition audit's dependency-soundness lens grades a case that
# breaks it as critical. This suite pins that text where each rule lives.
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

# The rule sits in the vertical-slice paragraph, which runs up to the routing ladder.
check_planner_rule() {
  local paragraph
  paragraph="$(range_of "$1/$PLANNER_REL" '**Cut phases as vertical slices.**' 'Route each UAT by the ladder below')"
  [ -n "$paragraph" ] || { printf 'vertical-slice paragraph not found\n' >&2; return 1; }
  need "$paragraph" 'The phase that owns a UAT builds every then-clause the UAT asserts' || return 1
  need "$paragraph" 'no earlier task builds what a later phase'"'"'s test asserts' || return 1
  need "$paragraph" 'passes on its phase'"'"'s base and can never record a RED' || return 1
}

check_dependency_lens() {
  local bullet
  bullet="$(range_of "$1/$AUDIT_REL" '- **Decomposition & dependency soundness (id prefix `DP`)' '- **Contract grounding (id prefix `CG`)')"
  [ -n "$bullet" ] || { printf 'dependency-soundness lens not found\n' >&2; return 1; }
  need "$bullet" 'A `New tests:` case asserting behavior an earlier phase'"'"'s task builds passes on its phase'"'"'s base and can never record a RED' || return 1
  need "$bullet" 'grade it `critical`' || return 1
  need "$bullet" 'move that build into the phase that owns the test' || return 1
}

# ---------- green ----------

@test "planner step 2 keeps every then-clause of a UAT in the phase that owns it" { green check_planner_rule; }
@test "the dependency-soundness lens grades a case an earlier phase satisfies as critical" { green check_dependency_lens; }

# ---------- red twins ----------

@test "red twin: dropping the owning-phase rule fails the planner check" {
  red check_planner_rule "$PLANNER_REL" 'The phase that owns a UAT builds every then-clause the UAT asserts' 'The phase that owns a UAT builds its main then-clause'
}

@test "red twin: allowing an earlier task to build an asserted clause fails the planner check" {
  red check_planner_rule "$PLANNER_REL" 'no earlier task builds what a later phase'"'"'s test asserts' 'an earlier task may build what a later phase'"'"'s test asserts'
}

@test "red twin: dropping the critical grade fails the lens check" {
  red check_dependency_lens "$AUDIT_REL" 'grade it `critical`' 'grade it `minor`'
}

@test "red twin: dropping the move-to-owning-phase fix fails the lens check" {
  red check_dependency_lens "$AUDIT_REL" 'move that build into the phase that owns the test' 'note it'
}
