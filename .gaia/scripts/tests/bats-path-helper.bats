#!/usr/bin/env bats
# The shared PATH primitives in .gaia/tests/helpers/path.sh.
#
# A bats suite that drives a "tool is not installed" arm on a developer machine
# where the tool really is installed needs a PATH with that tool guaranteed
# absent. The need arrived independently in suites across the tree, each with
# its own hand-rolled rebuild loop; a tree-wide grep for `helpers/path.sh`
# answers which suites are clients today. Separately, and not at every one of
# those loops, the membership test was written as `[ -x "$dir/$name" ]`.
#
# That predicate is wrong in one direction. `-x` is true for a searchable
# DIRECTORY named for the tool, not only for an executable file, so a PATH
# entry that merely holds such a directory was dropped along with every real
# tool it provides. bash's own PATH lookup accepts a regular file that is
# executable, which is `-f` and `-x` together.
#
# The direction is safe -- an over-strip removes a needed tool and fails the
# command under test rather than greening it -- so what makes this worth a
# primitive is the DUPLICATION rather than the defect. A rule with two homes
# gets repaired in one of them, and the copy nobody edited has nothing red to
# catch the drift. The client suites exercise the primitives through their own
# "not installed" arms against whatever the host PATH holds; this file pins that
# the two builders refuse to write outside a bats per-test temp dir, and what
# the mirroring rebuild resolves over a PATH built from fixture directories, so
# a change to how the shim is built is held to the same answers on every host.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
}

@test "path_shim_without refuses rather than writing outside a bats per-test temp dir" {
  # Sourced outside a test there is nowhere sanctioned to build the shim, and
  # picking one anyway would write where no caller asked. Asserted on the
  # diagnostic rather than on the status alone: a non-zero status is also what a
  # failed mkdir at an unwritable guessed path returns, so the status cannot
  # tell the refusal apart from the accident it exists to replace.
  local diagnostic_output exit_status=0
  diagnostic_output="$(BATS_TEST_TMPDIR="" path_shim_without uvx 2>&1)" || exit_status=$?
  [ "$exit_status" -ne 0 ]
  grep -qF 'BATS_TEST_TMPDIR is unset' <<<"$diagnostic_output"
}

@test "path_allowlist refuses rather than writing outside a bats per-test temp dir" {
  # Same refusal, and the same reason, as path_shim_without's: the directory is
  # torn down with the test that built it, so outside a test there is nowhere
  # sanctioned to build one. Asserted on the diagnostic rather than the status
  # alone, because a failed mkdir at a guessed path returns non-zero too.
  local diagnostic_output exit_status=0
  diagnostic_output="$(BATS_TEST_TMPDIR="" path_allowlist gaia-fixture-wanted 2>&1)" || exit_status=$?
  [ "$exit_status" -ne 0 ]
  grep -qF 'BATS_TEST_TMPDIR is unset' <<<"$diagnostic_output"
}

# make_fixture_command <directory> <name>: an executable regular file, which is
# what bash's PATH lookup accepts.
make_fixture_command() {
  mkdir -p "$1"
  printf '#!/bin/sh\n' >"$1/$2"
  chmod +x "$1/$2"
}

# resolve_under <path> <name>: what <name> resolves to on <path>, as the file a
# shim symlink points at. An absolute bash runs the lookup, since the rebuilt
# PATH need not hold one.
resolve_under() {
  local resolved
  resolved="$(PATH="$1" "$BASH" -c 'command -v "$1"' _ "$2")" || return 1
  if [ -L "$resolved" ]; then
    readlink "$resolved"
  else
    printf '%s\n' "$resolved"
  fi
}

@test "path_shim_without hides the named tool and keeps every command a mirrored or kept directory provides" {
  local mirrored="$BATS_TEST_TMPDIR/mirrored" kept="$BATS_TEST_TMPDIR/kept" rebuilt
  make_fixture_command "$mirrored" gaia-fixture-absent
  make_fixture_command "$mirrored" gaia-fixture-sibling
  make_fixture_command "$kept" gaia-fixture-elsewhere
  rebuilt="$(PATH="$mirrored:$kept:$PATH" path_shim_without gaia-fixture-absent)"
  resolve_under "$rebuilt" gaia-fixture-absent && return 1
  [ "$(resolve_under "$rebuilt" gaia-fixture-sibling)" = "$mirrored/gaia-fixture-sibling" ]
  [ "$(resolve_under "$rebuilt" gaia-fixture-elsewhere)" = "$kept/gaia-fixture-elsewhere" ]
}

@test "path_shim_without keeps an earlier mirrored directory's command ahead of a later one's" {
  local first="$BATS_TEST_TMPDIR/first" second="$BATS_TEST_TMPDIR/second" rebuilt
  make_fixture_command "$first" gaia-fixture-absent
  make_fixture_command "$first" gaia-fixture-shared
  make_fixture_command "$second" gaia-fixture-absent
  make_fixture_command "$second" gaia-fixture-shared
  make_fixture_command "$second" gaia-fixture-only-second
  rebuilt="$(PATH="$first:$second:$PATH" path_shim_without gaia-fixture-absent)"
  resolve_under "$rebuilt" gaia-fixture-absent && return 1
  [ "$(resolve_under "$rebuilt" gaia-fixture-shared)" = "$first/gaia-fixture-shared" ]
  [ "$(resolve_under "$rebuilt" gaia-fixture-only-second)" = "$second/gaia-fixture-only-second" ]
}
