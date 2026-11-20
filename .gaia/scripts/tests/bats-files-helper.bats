#!/usr/bin/env bats
# The shared byte-identity primitives in .gaia/tests/helpers/files.sh.
#
# Every byte-identity claim across the bats suites that consume it now rests
# on `assert_files_identical`, and a primitive that many assertions depend on is
# the worst place for an unproven one: an edit hollowing it back toward the
# `$(cat …)` comparison it replaced would green every consuming suite with nothing
# reddening anywhere. The suites it serves prove their own pins by mutation;
# this file holds the primitive to the same standard.
#
# The trailing-newline case is the one that matters, because it is the
# whole reason the helper exists: command substitution strips trailing newlines
# from both sides, so `a\n` and `a\n\n\n` compare EQUAL through `$(cat …)` and
# differ under `cmp`. The rejection test pins that difference directly.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"

  FIRST_FILE="$BATS_TEST_TMPDIR/a"
  SECOND_FILE="$BATS_TEST_TMPDIR/b"
}

@test "assert_files_identical accepts two files with identical bytes" {
  printf 'one\ntwo\n' > "$FIRST_FILE"
  printf 'one\ntwo\n' > "$SECOND_FILE"
  assert_files_identical "$FIRST_FILE" "$SECOND_FILE"
}

@test "assert_files_identical rejects differing or missing files" {
  printf 'one\ntwo\n' > "$FIRST_FILE"
  printf 'one\ntwo\n\n\n' > "$SECOND_FILE"

  # Written as a positive match on the bad case per the bats-assertions rule.
  assert_files_identical "$FIRST_FILE" "$SECOND_FILE" && {
    echo "the helper accepts a trailing-newline difference; it has decayed into the \$(cat …) comparison it replaced" >&2
    return 1
  }

  # And the control: that same pair IS equal through command substitution, which
  # is the defect this primitive exists to remove rather than a hypothetical.
  [ "$(cat "$FIRST_FILE")" = "$(cat "$SECOND_FILE")" ] || {
    echo "control broken: the fixture pair no longer demonstrates the \$(cat …) strip" >&2
    return 1
  }

  printf 'one\nTWO\n' > "$SECOND_FILE"
  assert_files_identical "$FIRST_FILE" "$SECOND_FILE" && { echo "accepts a pair differing in the middle" >&2; return 1; }

  # An absent path must never read as "identical". `cmp` exits non-zero and says
  # which path it could not open.
  assert_files_identical "$FIRST_FILE" "$BATS_TEST_TMPDIR/does-not-exist" && { echo "accepts a missing file" >&2; return 1; }
  true
}
