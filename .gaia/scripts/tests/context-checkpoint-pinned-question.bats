#!/usr/bin/env bats
#
# Suite for the audit loop's pinned question text staying byte-identical while the
# shared context lib grows new helpers and raises a band. The fixture was captured
# from the libs as committed before that change; the question builder keeps its own
# copy of the reading-summary math, so this compare is what notices a drift in
# either place.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/context-checkpoint-pinned-question.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/context-checkpoint/pinned-question.txt"
  LIBRARY_NAMES="context-checkpoint-lib.sh audit-loop-state-lib.sh branch-name-lib.sh main-root-lib.sh audit-key-lib.sh"
}

# emit_questions <library-directory>: the three fixture questions, one line each.
emit_questions() {
  . "$1/context-checkpoint-lib.sh"
  . "$1/audit-loop-state-lib.sh"
  gaia_loop_pinned_question feat/sample 0123456789abcdef 3 3 false false context "fresh 320000 1000000" grant 300000
  gaia_loop_pinned_question feat/sample 0123456789abcdef 3 3 true false rubric:stall "fresh 250000 1000000" grant 300000
  gaia_loop_pinned_question feat/sample 0123456789abcdef 6 3 false true cap "fresh 450000 1000000" stop 300000
}

# copy_libraries <destination>: a scratch copy of every library the builder sources.
copy_libraries() {
  local name
  mkdir -p "$1"
  for name in $LIBRARY_NAMES; do
    cp "$REPO_ROOT/.gaia/scripts/$name" "$1/$name"
  done
}

@test "the fixture holds three non-empty question lines" {
  [ "$(wc -l <"$FIXTURE" | tr -d ' ')" = "3" ]
  [ "$(grep -c '^{"questions":' "$FIXTURE")" = "3" ]
}

@test "the pinned question lines match the fixture byte for byte" {
  local actual="$BATS_TEST_TMPDIR/actual.txt"
  (emit_questions "$REPO_ROOT/.gaia/scripts") >"$actual"
  cmp "$actual" "$FIXTURE"
}

@test "red twin: a changed summary format in the question builder fails the compare" {
  local scratch="$BATS_TEST_TMPDIR/mutant" actual="$BATS_TEST_TMPDIR/mutant-actual.txt"
  copy_libraries "$scratch"
  sed 's/k of /K of /g' "$scratch/audit-loop-state-lib.sh" >"$scratch/audit-loop-state-lib.sh.new"
  mv "$scratch/audit-loop-state-lib.sh.new" "$scratch/audit-loop-state-lib.sh"
  # The mutation must actually have changed the copy.
  run cmp -s "$scratch/audit-loop-state-lib.sh" "$REPO_ROOT/.gaia/scripts/audit-loop-state-lib.sh"
  [ "$status" -ne 0 ]
  (emit_questions "$scratch") >"$actual"
  run cmp -s "$actual" "$FIXTURE"
  [ "$status" -ne 0 ]
}
