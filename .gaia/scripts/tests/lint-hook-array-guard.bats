#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-hook-array-guard.sh: the static gate that flags
# unguarded bare "${arr[@]}" / "${arr[*]}" expansions under `set -u`, the bash
# 3.2.57 empty-array abort class the bash-5 bats suites are blind to. The gate
# walks .claude/hooks/**/*.sh recursively, the sourced libraries under lib/
# included, every shipped .gaia/scripts/**/*.sh, and the framework test bash
# under .gaia/tests/**/*.sh.
#
# Two jobs: prove the detector fires on a known-bad fixture in each scanned tree
# (including a subdirectory of each recursive tree, so the walk is covered) and
# stays quiet on each guarded form (offset-guard, count-guard, no-set-u,
# comment), and assert the real scanned tree is clean so a regression fails CI.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
# The linter is invoked as `bash "$LINTER"` from a fixture cwd, matching
# how CI runs it from the repo root; it scans `.claude/hooks/**/*.sh`,
# `.gaia/scripts/**/*.sh` and `.gaia/tests/**/*.sh` relative to cwd.
#
# One asymmetry the fixtures below cover on both sides: whether a file runs
# under `set -u` is read from the file's own text everywhere except
# `.claude/hooks/lib/`, whose modules are sourced into callers that already set
# it. A library fixture setting nothing is still scanned; a root hook setting
# nothing is still skipped.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-hook-array-guard.sh"
  TEMPORARY_DIRECTORY=""
}

teardown() {
  [ -n "$TEMPORARY_DIRECTORY" ] && [ -d "$TEMPORARY_DIRECTORY" ] && rm -rf "$TEMPORARY_DIRECTORY"
  return 0
}

# fixture_hook <body>: a tmp repo with one .claude/hooks/probe.sh holding <body>.
# Sets $TEMPORARY_DIRECTORY. Run the linter from $TEMPORARY_DIRECTORY so its cwd-relative scan resolves.
fixture_hook() {
  TEMPORARY_DIRECTORY="$(mktemp -d -t array-guard-lint-XXXXXX)"
  mkdir -p "$TEMPORARY_DIRECTORY/.claude/hooks"
  printf '%s\n' "$1" > "$TEMPORARY_DIRECTORY/.claude/hooks/probe.sh"
}

# fixture_script <relative_path> <body>: a tmp repo with one .gaia/scripts/<relative_path>
# holding <body>. Sets $TEMPORARY_DIRECTORY. <relative_path> may name a subdirectory so the recursive
# walk is exercised. Run the linter from $TEMPORARY_DIRECTORY so its cwd-relative scan resolves.
fixture_script() {
  TEMPORARY_DIRECTORY="$(mktemp -d -t array-guard-lint-XXXXXX)"
  mkdir -p "$TEMPORARY_DIRECTORY/.gaia/scripts/$(dirname "$1")"
  printf '%s\n' "$2" > "$TEMPORARY_DIRECTORY/.gaia/scripts/$1"
}

# fixture_test_script <relative_path> <body>: a tmp repo with one .gaia/tests/<relative_path>
# holding <body>. Sets $TEMPORARY_DIRECTORY. <relative_path> may name a subdirectory so the recursive
# walk is exercised. Run the linter from $TEMPORARY_DIRECTORY so its cwd-relative scan resolves.
fixture_test_script() {
  TEMPORARY_DIRECTORY="$(mktemp -d -t array-guard-lint-XXXXXX)"
  mkdir -p "$TEMPORARY_DIRECTORY/.gaia/tests/$(dirname "$1")"
  printf '%s\n' "$2" > "$TEMPORARY_DIRECTORY/.gaia/tests/$1"
}

# 6. The sourced libraries under .claude/hooks/lib/ are scanned too, recursively.
#
# They are function modules sourced into hooks running `set -euo pipefail`, so
# `set -u` is in effect for their code at runtime whether or not the file sets
# it itself. scan_file's precondition asks whether the FILE sets `set -u`, the
# right question for a standalone script and the wrong one for a sourced
# module, so lib/ is exempt from it. Two of the cases below carry that split:
# one library that sets `set -u` and one that does not, because only the second
# distinguishes the exemption from the walk, and the last case pins the
# exemption's boundary by asserting a root hook is still held to the
# precondition.

# fixture_library <relative_path> <body>: a tmp repo with one .claude/hooks/lib/<relative_path>
# holding <body>. Sets $TEMPORARY_DIRECTORY. <relative_path> may name a subdirectory so the recursive
# walk is exercised. Run the linter from $TEMPORARY_DIRECTORY so its cwd-relative scan resolves.
fixture_library() {
  TEMPORARY_DIRECTORY="$(mktemp -d -t array-guard-lint-XXXXXX)"
  mkdir -p "$TEMPORARY_DIRECTORY/.claude/hooks/lib/$(dirname "$1")"
  printf '%s\n' "$2" > "$TEMPORARY_DIRECTORY/.claude/hooks/lib/$1"
}

# lint_case <label> <expected status> <expected path:line | ->: run the linter from the
# fixture the caller just built, echo the label so a red case names itself, assert
# the status, then the located line on a refusal. The fixture is removed after
# each case so the next builds its own.
lint_case() {
  echo "case: $1"
  run bash -c "cd '$TEMPORARY_DIRECTORY' && bash '$LINTER'"
  rm -rf "$TEMPORARY_DIRECTORY"
  [ "$status" -eq "$2" ]
  if [ "$2" -eq 1 ]; then
    grep -qF -- "$3" <<<"$output"
  fi
  return 0
}

# lint_case_unguarded <label> <path:line>: a refusal case that also asserts the
# word "unguarded" in the report. lint_case removes the fixture but leaves $output.
lint_case_unguarded() {
  lint_case "$1" 1 "$2"
  grep -qF -- "unguarded" <<<"$output"
}

# 2. The detector fires on an unguarded bare expansion under set -u

# bats test_tags=protected
@test "flags an unguarded bare \${arr[@]} under set -u" {
  fixture_hook $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TEMPORARY_DIRECTORY' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:4" <<<"$output"
  grep -qF -- "unguarded" <<<"$output"
}

@test "flags an unguarded bare array expansion in every scan root, spelling and recursion" {
  fixture_hook $'#!/usr/bin/env bash\nset -u\narr=()\nprintf "%s\\n" "${arr[*]}"'
  lint_case 'arr[*] under set -u in hooks' 1 ".claude/hooks/probe.sh:4"

  fixture_script probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" "${arr[@]}"'
  lint_case_unguarded 'arr[@] in .gaia/scripts' ".gaia/scripts/probe.sh:4"

  fixture_script sub/deep.sh $'#!/usr/bin/env bash\nset -u\narr=()\nprintf "%s\\n" "${arr[@]}"'
  lint_case 'recurses into .gaia/scripts subdirectories' 1 ".gaia/scripts/sub/deep.sh:4"

  fixture_test_script probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" "${arr[@]}"'
  lint_case_unguarded 'arr[@] in .gaia/tests' ".gaia/tests/probe.sh:4"

  fixture_test_script sub/deep.sh $'#!/usr/bin/env bash\nset -u\narr=()\nprintf "%s\\n" "${arr[@]}"'
  lint_case 'recurses into .gaia/tests subdirectories' 1 ".gaia/tests/sub/deep.sh:4"

  fixture_library probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" "${arr[@]}"'
  lint_case_unguarded 'arr[@] in hooks/lib that sets set -u' ".claude/hooks/lib/probe.sh:4"

  fixture_library inherits.sh $'#!/usr/bin/env bash\n# shellcheck shell=bash\narr=()\nprintf "%s\\n" "${arr[@]}"'
  lint_case_unguarded 'arr[@] in hooks/lib that sets no set -u of its own' ".claude/hooks/lib/inherits.sh:4"

  fixture_library sub/deep.sh $'#!/usr/bin/env bash\nset -u\narr=()\nprintf "%s\\n" "${arr[@]}"'
  lint_case 'recurses into .claude/hooks subdirectories' 1 ".claude/hooks/lib/sub/deep.sh:4"
}

@test "a file outside hooks/lib with no set -u is not scanned" {
  fixture_hook $'#!/usr/bin/env bash\narr=()\nprintf "%s\\n" "${arr[@]}"'
  lint_case 'a root hook with no set -u is not scanned, unlike hooks/lib' 0 -
}

@test "guarded and comment forms pass in every scan root" {
  fixture_hook $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" ${arr[@]+"${arr[@]}"}'
  lint_case 'offset-guarded in hooks' 0 -

  fixture_hook $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\n[ "${#arr[@]}" -eq 0 ] || printf "%s\\n" "${arr[@]}"'
  lint_case 'count-guarded in hooks' 0 -

  fixture_hook $'#!/usr/bin/env bash\nset -u\n# printf "%s\\n" "${arr[@]}"'
  lint_case 'full-line comment in hooks' 0 -

  fixture_script probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" ${arr[@]+"${arr[@]}"}'
  lint_case 'offset-guarded in .gaia/scripts' 0 -

  fixture_test_script probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" ${arr[@]+"${arr[@]}"}'
  lint_case 'offset-guarded in .gaia/tests' 0 -

  fixture_library probe.sh $'#!/usr/bin/env bash\narr=()\nprintf "%s\\n" ${arr[@]+"${arr[@]}"}'
  lint_case 'offset-guarded in hooks/lib' 0 -

  fixture_library probe.sh $'#!/usr/bin/env bash\narr=()\n[ "${#arr[@]}" -eq 0 ] || printf "%s\\n" "${arr[@]}"'
  lint_case 'count-guarded in hooks/lib' 0 -

  fixture_library probe.sh $'#!/usr/bin/env bash\n# printf "%s\\n" "${arr[@]}"'
  lint_case 'full-line comment in hooks/lib' 0 -
}
