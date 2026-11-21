#!/usr/bin/env bats

# Adversarial suite for .gaia/scripts/assert-no-release-leak.sh, the shipped-tree
# leak assertion release.yml runs against the very tree that becomes the tarball.
#
# The defect this guards (#2061) is that the assertion's predecessor derived its
# verdict from a command substitution whose producer failure was unobservable.
# An empty result was read as "nothing leaked", and empty is also what the
# pipeline produced when the `cd` did not land, `find` aborted part way through
# an unreadable directory, or `sed` died: the substitution's status was `grep`'s
# alone, and `|| true` swallowed even that. The failure direction was fail-open
# on the gate deciding whether a maintainer-only path ships to every adopter,
# and nothing in the repository went red when the scan did not happen.
#
# The script tests drive the ordinary contract: the clean pass, the refusal that
# names the leaked paths, and each way the question can be left unanswerable.
#
# The caller test binds release.yml, so the repaired shape cannot return to it
# silently.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]], POSIX [ ] and grep only, so a broken assertion still fails on
# macOS bash 3.2.
#
# Maintainer-only. `.gaia/scripts/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/assert-no-release-leak.sh"
  STAGING="$BATS_TEST_TMPDIR/staging"
  REGEX="$BATS_TEST_TMPDIR/exclude-regex.txt"
  mkdir -p "$STAGING"
}

teardown() {
  # A fixture that drops a directory to mode 000 would otherwise defeat bats'
  # own tmpdir cleanup.
  chmod -R u+rwX "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# Stage $1 (a staging-relative path) holding a one-line body.
stage() {
  local relative_path="$1"
  mkdir -p "$STAGING/$(dirname "$relative_path")"
  printf 'content\n' > "$STAGING/$relative_path"
}

# Write the compiled exclude patterns, one per line, in the anchored form
# `gaia-maintainer release exclude-regex` emits.
patterns() {
  printf '%s\n' "$@" > "$REGEX"
}

# E1. Exit 0 when the scan completes and finds nothing: a staged tree holding
# nothing the exclude list withholds, and an empty compiled exclude list, which
# withholds nothing so nothing can leak. The empty list is the one empty input
# that is an answer rather than an absent one.
@test "exit 0 when scanned clean: no excluded path, and an empty exclude list" {
  stage 'app/index.ts'
  stage 'README.md'
  patterns '^\.gaia/scripts/tests(/|$)'
  run bash "$SCRIPT" "$STAGING" "$REGEX"
  [ "$status" -eq 0 ] || { echo "no excluded path: status $status"; return 1; }

  : > "$REGEX"
  run bash "$SCRIPT" "$STAGING" "$REGEX"
  [ "$status" -eq 0 ] || { echo "empty exclude list: status $status"; return 1; }
}

# E2. The refusal, and the paths it names. The exit code alone is not the claim:
# a maintainer reads the annotation to learn which file leaked.
# bats test_tags=protected
@test "E2: an excluded path in the staged tree refuses and names it" {
  stage 'app/index.ts'
  stage '.gaia/scripts/tests/secret.bats'
  patterns '^\.gaia/scripts/tests(/|$)'

  run bash "$SCRIPT" "$STAGING" "$REGEX"
  [ "$status" -eq 1 ]
  grep -qF -- '.gaia/scripts/tests/secret.bats' <<<"$output"
}

# Exit 2 on every unanswerable input. Each is the question left unanswered, never
# a clean pass; release.yml treats any non-zero, non-1 status as an unproven scan.
# An unreadable subdirectory stops `find` short, an empty staged tree (a
# staging step that copied nothing) satisfies any leak scan trivially, and an
# uncompilable pattern makes `grep` exit above 1.
@test "exit 2 on every unanswerable input: wrong argument count, missing staging directory, missing regex file, unreadable subdirectory, empty staged tree, uncompilable pattern" {
  run bash "$SCRIPT" "$STAGING"
  [ "$status" -eq 2 ] || { echo "wrong argument count: status $status"; return 1; }
  grep -qF -- 'usage:' <<<"$output" || { echo "wrong argument count: $output"; return 1; }

  patterns '^\.gaia/scripts/tests(/|$)'
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/nope" "$REGEX"
  [ "$status" -eq 2 ] || { echo "missing staging directory: status $status"; return 1; }
  grep -qF -- 'missing or is not a directory' <<<"$output" || { echo "missing staging directory: $output"; return 1; }

  run bash "$SCRIPT" "$STAGING" "$REGEX"
  [ "$status" -eq 2 ] || { echo "empty staged tree: status $status"; return 1; }
  grep -qF -- 'holds no files' <<<"$output" || { echo "empty staged tree: $output"; return 1; }

  stage 'app/index.ts'
  run bash "$SCRIPT" "$STAGING" "$BATS_TEST_TMPDIR/nope.txt"
  [ "$status" -eq 2 ] || { echo "missing regex file: status $status"; return 1; }
  grep -qF -- 'missing or unreadable' <<<"$output" || { echo "missing regex file: $output"; return 1; }

  patterns '^\.gaia/scripts/tests[(/|$'
  run bash "$SCRIPT" "$STAGING" "$REGEX"
  [ "$status" -eq 2 ] || { echo "uncompilable pattern: status $status"; return 1; }
  grep -qF -- 'UNPROVEN' <<<"$output" || { echo "uncompilable pattern: $output"; return 1; }

  # Root traverses a mode-000 directory, so this row cannot arm there.
  if [ "$(id -u)" -ne 0 ]; then
    mkdir -p "$STAGING/.gaia/scripts/tests"
    printf 'leaked\n' > "$STAGING/.gaia/scripts/tests/secret.bats"
    chmod 000 "$STAGING/.gaia/scripts"
    patterns '^\.gaia/scripts/tests(/|$)'
    run bash "$SCRIPT" "$STAGING" "$REGEX"
    [ "$status" -eq 2 ] || { echo "unreadable subdirectory: status $status"; return 1; }
    grep -qF -- 'UNPROVEN' <<<"$output" || { echo "unreadable subdirectory: $output"; return 1; }
  fi
  return 0
}

# C2. The caller must also read the script's status rather than discarding it,
# because discarding it restores the exact fail-open the script exists to close,
# one layer up.
#
# This pins the whole status-capturing block, rather than scanning the
# invocation's neighbourhood for a forbidden spelling. A scan is the shape that
# reads as stricter and is not: its match region is whichever lines carry the
# script's name, so `|| :` on the same line and `|| true` on a backslash
# continuation both escape it, and either one leaves the status variable at its
# initialised zero with both workflow arms skipped and this test green.
# release.yml already writes several commands across backslash continuations,
# one of them a command whose status is read, so the escaping spelling is one an
# ordinary reflow produces.
#
# Two properties of the pin are load-bearing, and the second is the one a
# substring pin silently lacks. It reads only lines that are not YAML comments,
# because a pin matched anywhere in the file is satisfied by its own subject sat
# inside a comment: prefixing the invocation with a `#` disables the whole
# assertion and leaves an unanchored pin green. And it requires the lines to be
# contiguous and in order, so an arm cannot be deleted, reordered, or downgraded
# from `exit 1` to a warning while the remaining fragments still satisfy three
# independent line matches. What this pin therefore claims, exactly: the block
# below appears in release.yml as live shell, in this order, with nothing
# between its lines. Any edit to it reds here and the failure prints the block
# to compare against.
@test "C2: release.yml captures the leak assertion's status and acts on it" {
  local live expected
  live="$(grep -vE '^[[:space:]]*#' "$REPO_ROOT/.github/workflows/release.yml" \
    | sed 's/^[[:space:]]*//' | tr '\n' '\001')"
  # The pin literals below carry $STAGING, $? and $leak_exit_status as text, which is the
  # point: expanding them in this shell would build a needle matching nothing.
  # shellcheck disable=SC2016
  expected="$(printf '%s\001' \
    'leak_exit_status=0' \
    'bash .gaia/scripts/assert-no-release-leak.sh "$STAGING" /tmp/exclude-regex.txt || leak_exit_status=$?' \
    'if [ "$leak_exit_status" -eq 1 ]; then' \
    'echo "::error::release-excluded path(s) leaked into $STAGING; see the paths above" >&2' \
    'exit 1' \
    'elif [ "$leak_exit_status" -ne 0 ]; then' \
    'echo "::error::shipped-tree leak scan did not complete (exit $leak_exit_status); leak-freedom is unproven" >&2' \
    'exit 1' \
    'fi')"
  grep -qF -- "$expected" <<<"$live"
}
