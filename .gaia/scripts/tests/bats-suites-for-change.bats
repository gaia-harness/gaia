#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/bats-suites-for-change.sh, the one owner
# of "every bats suite that references a file the change edits or deletes".
#
# The pin that matters most is the first test: a changed path holding a space
# selects only the suites naming its whole basename. A hand-rolled
# `for f in $(git diff --name-only ...)` word-splits that path into fragments
# (`PR`, `Merge`, `Workflow.md`) that match nearly every suite, so the fixture
# carries one suite per fragment and asserts none of them is selected.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/bats-suites-for-change.bats
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/bats-suites-for-change.sh"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  build_fixture
}

# build_fixture: (re)create the fixture repository from scratch, so a test
# holding several cases gives each its own tree.
build_fixture() {
  rm -rf "$FIXTURE"
  mkdir -p "$FIXTURE/wiki" "$FIXTURE/tests" "$FIXTURE/scripts"
  git -C "$FIXTURE" init -q -b main
  git -C "$FIXTURE" config user.email t@example.com
  git -C "$FIXTURE" config user.name t
  git -C "$FIXTURE" config commit.gpgsign false

  printf 'one\n' > "$FIXTURE/wiki/PR Merge Workflow.md"
  printf 'two\n' > "$FIXTURE/wiki/other.md"
  printf 'three\n' > "$FIXTURE/scripts/gone.sh"
  printf '# reads PR Merge Workflow.md\n' > "$FIXTURE/tests/names-it.bats"
  printf '# PR\n' > "$FIXTURE/tests/fragment-pr.bats"
  printf '# Merge\n' > "$FIXTURE/tests/fragment-merge.bats"
  printf '# Workflow.md\n' > "$FIXTURE/tests/fragment-workflow.bats"
  printf '# sources gone.sh\n' > "$FIXTURE/tests/names-gone.bats"
  printf '# unrelated\n' > "$FIXTURE/tests/unrelated.bats"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m base
  BASE="$(git -C "$FIXTURE" rev-parse HEAD)"
  # The default mode diffs against the merge base with the remote default
  # branch; a remote-tracking ref is all it reads, so no real remote is needed.
  git -C "$FIXTURE" update-ref refs/remotes/origin/main "$BASE"
}

@test "a changed path holding a space selects only suites naming its whole basename" {
  printf 'edited\n' >> "$FIXTURE/wiki/PR Merge Workflow.md"
  git -C "$FIXTURE" commit -q -am edit

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "tests/names-it.bats" ] || {
    printf 'got:\n%s\n' "$output" >&2
    return 1
  }
}

@test "a deleted or renamed file still selects the suites naming it, including an uncommitted rename in default mode" {
  git -C "$FIXTURE" rm -q scripts/gone.sh
  git -C "$FIXTURE" commit -q -m delete
  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ] || { echo "deleted: status $status"; return 1; }
  [ "$output" = "tests/names-gone.bats" ] || { echo "deleted: got '$output'"; return 1; }

  build_fixture
  git -C "$FIXTURE" mv scripts/gone.sh scripts/renamed.sh
  git -C "$FIXTURE" commit -q -m rename
  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ] || { echo "renamed: status $status"; return 1; }
  [ "$output" = "tests/names-gone.bats" ] || { echo "renamed: got '$output'"; return 1; }

  build_fixture
  git -C "$FIXTURE" mv scripts/gone.sh scripts/renamed.sh
  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE"
  [ "$status" -eq 0 ] || { echo "renamed, default mode: status $status"; return 1; }
  [ "$output" = "tests/names-gone.bats" ] || { echo "renamed, default mode: got '$output'"; return 1; }
}
@test "a changed suite selects itself even when nothing names it" {
  printf '# edited\n' >> "$FIXTURE/tests/unrelated.bats"
  git -C "$FIXTURE" commit -q -am edit-suite

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "tests/unrelated.bats" ]
}

# Writes each "<path>=<content>" pair into the fixture and commits them as the
# new base, printing its commit.
commit_base_files() {
  local pair
  for pair in "$@"; do
    mkdir -p "$(dirname "$FIXTURE/${pair%%=*}")"
    printf '%s\n' "${pair#*=}" > "$FIXTURE/${pair%%=*}"
  done
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m files
  git -C "$FIXTURE" rev-parse HEAD
}

@test "a root-level file selects suites reading it through a root, not suites using its name as data" {
  base="$(commit_base_files \
    'CHANGELOG.md=# changelog' \
    'tests/reads-changelog.bats=body="$(cat "$REPO_ROOT/CHANGELOG.md")"' \
    'tests/fixture-changelog.bats=commit_files CHANGELOG.md "entry"')"
  printf 'edited\n' >> "$FIXTURE/CHANGELOG.md"
  git -C "$FIXTURE" commit -q -am edit

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "tests/reads-changelog.bats" ] || {
    printf 'got:\n%s\n' "$output" >&2
    return 1
  }
}

@test "a suite declaring a file fixture-only is selected only by the changed paths it does not declare" {
  base="$(commit_base_files \
    'CHANGELOG.md=# changelog' \
    'scripts/tool.sh=a' \
    'tests/reads-changelog.bats=body="$(cat "$REPO_ROOT/CHANGELOG.md")"' \
    $'tests/scratch-changelog.bats=# bats-selector fixture-only: CHANGELOG.md\necho x > "$ROOT/CHANGELOG.md"; bash "$SCRIPTS/tool.sh"')"
  printf 'edited\n' >> "$FIXTURE/CHANGELOG.md"
  git -C "$FIXTURE" commit -q -am changelog

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "tests/reads-changelog.bats" ] || {
    printf 'changelog only, got:\n%s\n' "$output" >&2
    return 1
  }

  printf 'edited\n' >> "$FIXTURE/scripts/tool.sh"
  git -C "$FIXTURE" commit -q -am tool
  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = $'tests/reads-changelog.bats\ntests/scratch-changelog.bats' ] || {
    printf 'changelog and tool, got:\n%s\n' "$output" >&2
    return 1
  }
}

@test "a changed file selects suites by its unique trailing path (shared-basename source, deleted, in a tree holding a suite, unique basename, non-source, basename inside a directory path)" {
  build_fixture
  base="$(commit_base_files \
    'apps/web/app/form-error/index.tsx=a' \
    'apps/web/app/form-error/tests/index.test.tsx=b' \
    'apps/web/app/date/index.tsx=c' \
    'apps/web/app/date/tests/index.test.tsx=d' \
    'tests/component-source.bats=# reads apps/web/app/form-error/index.tsx' \
    'tests/component-test.bats=# reads form-error/tests/index.test.tsx' \
    'tests/fixture-index.bats=stage index.tsx tests/index.test.tsx')"
  printf 'edited\n' >> "$FIXTURE/apps/web/app/form-error/index.tsx"
  printf 'edited\n' >> "$FIXTURE/apps/web/app/form-error/tests/index.test.tsx"
  git -C "$FIXTURE" commit -q -am edit

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
  [ "$status" -eq 0 ] || { echo "source file in a tree with no suite: status $status"; return 1; }
  expected="$(printf 'tests/component-source.bats\ntests/component-test.bats')"
  [ "$output" = "$expected" ] || { echo "source file in a tree with no suite: got '$output'"; return 1; }
  build_fixture
  base="$(commit_base_files \
    'apps/web/app/form-error/index.tsx=a' \
    'apps/web/app/date/index.tsx=c' \
    'tests/date-source.bats=# reads app/date/index.tsx' \
    'tests/fixture-index.bats=stage index.tsx')"
  git -C "$FIXTURE" rm -q apps/web/app/date/index.tsx
  git -C "$FIXTURE" commit -q -m delete

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
  [ "$status" -eq 0 ] || { echo "deleted source file: status $status"; return 1; }
  [ "$output" = "tests/date-source.bats" ] || { echo "deleted source file: got '$output'"; return 1; }
  build_fixture
  base="$(commit_base_files \
    'tools/storage/index.ts=a' \
    'tools/wiki/index.ts=b' \
    'tools/tests/storage.bats=import from "$storage_directory/index.ts"')"
  printf 'edited\n' >> "$FIXTURE/tools/storage/index.ts"
  git -C "$FIXTURE" commit -q -am edit

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
  [ "$status" -eq 0 ] || { echo "source file in a tree holding a suite: status $status"; return 1; }
  [ "$output" = "tools/tests/storage.bats" ] || { echo "source file in a tree holding a suite: got '$output'"; return 1; }
  build_fixture
  base="$(commit_base_files \
    'apps/web/app/date/year-month-day.tsx=a' \
    'tests/names-date.bats=# reads "$COMPONENTS/year-month-day.tsx"')"
  printf 'edited\n' >> "$FIXTURE/apps/web/app/date/year-month-day.tsx"
  git -C "$FIXTURE" commit -q -am edit

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
  [ "$status" -eq 0 ] || { echo "source file with a unique basename: status $status"; return 1; }
  [ "$output" = "tests/names-date.bats" ] || { echo "source file with a unique basename: got '$output'"; return 1; }
  build_fixture
  base="$(commit_base_files \
    'config/hooks/settings.json={}' \
    'config/settings.json={}' \
    'tests/reads-settings.bats=SETTINGS="${HOOKS_SOURCE_DIRECTORY%/hooks}/settings.json"')"
  printf 'edited\n' >> "$FIXTURE/config/settings.json"
  git -C "$FIXTURE" commit -q -am edit

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
  [ "$status" -eq 0 ] || { echo "non-source file: status $status"; return 1; }
  [ "$output" = "tests/reads-settings.bats" ] || { echo "non-source file: got '$output'"; return 1; }
  build_fixture
  base="$(commit_base_files \
    '.gaia/cli/gaia=bundle' \
    '.gaia/cli/src/main.ts=a' \
    'tests/runs-bundle.bats=run "$REPO_ROOT/.gaia/cli/gaia" packages' \
    'tests/runs-script.bats=run bash "$REPO_ROOT/.gaia/scripts/other.sh"')"
  printf 'edited\n' >> "$FIXTURE/.gaia/cli/gaia"
  git -C "$FIXTURE" commit -q -am edit

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
  [ "$status" -eq 0 ] || { echo "basename inside a directory path: status $status"; return 1; }
  [ "$output" = "tests/runs-bundle.bats" ] || { echo "basename inside a directory path: got '$output'"; return 1; }
}
@test "a deleted suite is not printed, since there is nothing left to run" {
  git -C "$FIXTURE" rm -q tests/unrelated.bats
  git -C "$FIXTURE" commit -q -m drop-suite

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no argument covers committed, uncommitted, and untracked changes since the merge base" {
  printf 'committed\n' >> "$FIXTURE/wiki/PR Merge Workflow.md"
  git -C "$FIXTURE" commit -q -am committed
  printf 'uncommitted\n' >> "$FIXTURE/scripts/gone.sh"
  printf 'new\n' > "$FIXTURE/wiki/fresh.md"
  printf '# reads fresh.md\n' > "$FIXTURE/tests/names-fresh.bats"

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE"
  [ "$status" -eq 0 ]
  expected="$(printf 'tests/names-fresh.bats\ntests/names-gone.bats\ntests/names-it.bats')"
  [ "$output" = "$expected" ] || {
    printf 'got:\n%s\n' "$output" >&2
    return 1
  }
}

@test "HEAD covers only the staged round delta, not changes an earlier commit made" {
  printf 'earlier round\n' >> "$FIXTURE/wiki/PR Merge Workflow.md"
  git -C "$FIXTURE" commit -q -am earlier
  printf 'this round\n' >> "$FIXTURE/scripts/gone.sh"
  printf 'new\n' > "$FIXTURE/wiki/fresh.md"
  printf '# reads fresh.md\n' > "$FIXTURE/tests/names-fresh.bats"
  git -C "$FIXTURE" add -A

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" HEAD
  [ "$status" -eq 0 ]
  expected="$(printf 'tests/names-fresh.bats\ntests/names-gone.bats')"
  [ "$output" = "$expected" ] || {
    printf 'got:\n%s\n' "$output" >&2
    return 1
  }
}

@test "no change prints nothing and exits 0" {
  # Files holding the literal `*.bats`, which an empty pattern list would let
  # git grep take as its pattern and print.
  printf '# runs every *.bats\n' > "$FIXTURE/tests/names-the-glob.bats"
  printf 'lists *.bats\n' > "$FIXTURE/wiki/glob.md"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m glob
  git -C "$FIXTURE" update-ref refs/remotes/origin/main HEAD

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a failing read fails loudly instead of reporting no suites (unreadable diff, failing suite search)" {
  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" no-such-revision HEAD
  [ "$status" -eq 3 ] || { echo "unreadable diff: status $status"; return 1; }
  [ -z "$output" ] || { echo "unreadable diff: got '$output'"; return 1; }
  grep -qF "bats-suites-for-change" <<<"$stderr" || { echo "unreadable diff: stderr '$stderr'"; return 1; }

  printf 'edited\n' >> "$FIXTURE/wiki/PR Merge Workflow.md"
  git -C "$FIXTURE" commit -q -am edit
  # A git that answers every subcommand but grep, which it fails the way an
  # unreadable object store does (status 128, not grep's no-match 1).
  real_git="$(command -v git)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nfor argument in "$@"; do [ "$argument" = grep ] && exit 128; done\nexec "%s" "$@"\n' \
    "$real_git" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 3 ] || { echo "failing suite search: status $status"; return 1; }
  [ -z "$output" ]
}
@test "every changed path selects its own suites when the change spans several" {
  printf 'edited\n' >> "$FIXTURE/wiki/PR Merge Workflow.md"
  git -C "$FIXTURE" rm -q scripts/gone.sh
  printf 'edited\n' >> "$FIXTURE/wiki/other.md"
  git -C "$FIXTURE" commit -q -am several

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = $'tests/names-gone.bats\ntests/names-it.bats' ] || {
    printf 'got:\n%s\n' "$output" >&2
    return 1
  }
}

@test "one suite search covers the whole change, however many paths it holds" {
  printf 'edited\n' >> "$FIXTURE/wiki/PR Merge Workflow.md"
  git -C "$FIXTURE" rm -q scripts/gone.sh
  printf 'edited\n' >> "$FIXTURE/wiki/other.md"
  git -C "$FIXTURE" commit -q -am several
  # A git that logs each grep it is asked for, then runs it for real.
  real_git="$(command -v git)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nfor argument in "$@"; do [ "$argument" = grep ] && echo grep >> "%s"; done\nexec "%s" "$@"\n' \
    "$BATS_TEST_TMPDIR/grep-calls" "$real_git" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/grep-calls" | tr -d ' ')" -eq 1 ]
}

@test "no remote default branch exits 3 naming the fix, an unknown option exits 2" {
  git -C "$FIXTURE" update-ref -d refs/remotes/origin/main

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE"
  [ "$status" -eq 3 ] || { echo "no remote default branch: status $status"; return 1; }
  [ -z "$output" ] || { echo "no remote default branch: got '$output'"; return 1; }
  grep -qF "pass a range" <<<"$stderr" || { echo "no remote default branch: stderr '$stderr'"; return 1; }

  run --separate-stderr bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}
