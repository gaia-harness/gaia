#!/usr/bin/env bats
#
# Suite for the audit loop's pinned question text staying byte-identical while the
# shared context lib grows new helpers and raises a band. The fixture was captured
# from the libs as committed before that change; the question builder reads its
# reading summary and its side of the line from that lib's gaia_context_summary
# and gaia_context_band, so this compare is what notices a drift in either one.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/context-checkpoint-pinned-question.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/context-checkpoint/pinned-question.txt"
}

# emit_questions <library-directory>: the four fixture questions, one line each.
emit_questions() {
  . "$1/context-checkpoint-lib.sh"
  . "$1/audit-loop-state-lib.sh"
  gaia_loop_pinned_question feat/sample 0123456789abcdef 3 3 false false context "fresh 320000 1000000" grant 300000
  gaia_loop_pinned_question feat/sample 0123456789abcdef 3 3 true false rubric:stall "fresh 250000 1000000" grant 300000
  gaia_loop_pinned_question feat/sample 0123456789abcdef 6 3 false true cap "fresh 450000 1000000" stop 300000
  gaia_loop_pinned_question feat/sample 0123456789abcdef 4 3 true false rubric:enriching "fresh 250000 1000000" accept 300000
}

@test "the fixture holds four non-empty question lines" {
  [ "$(wc -l <"$FIXTURE" | tr -d ' ')" = "4" ]
  [ "$(grep -c '^{"questions":' "$FIXTURE")" = "4" ]
}

@test "the pinned question lines match the fixture byte for byte" {
  local actual="$BATS_TEST_TMPDIR/actual.txt"
  (emit_questions "$REPO_ROOT/.gaia/scripts") >"$actual"
  cmp "$actual" "$FIXTURE"
}
