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

# Commits the given suites over a fixture holding CHANGELOG.md, edits
# CHANGELOG.md, and leaves the selector's output in $output.
select_on_changelog_edit() {
  local base
  base="$(commit_base_files 'CHANGELOG.md=# changelog' "$@")"
  printf 'edited\n' >> "$FIXTURE/CHANGELOG.md"
  git -C "$FIXTURE" commit -q -am changelog
  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
}

@test "a suite naming a changed file only as fixture data it writes under a temporary root is not selected; a read through the repo root, an unknown root, a root cut by a parameter expansion, a helper's root, an unwritten fixture or a path above the root is" {
  select_on_changelog_edit \
    $'tests/fixture-write.bats=ROOT="$BATS_TEST_TMPDIR/fixture"\nprintf x > "$ROOT/CHANGELOG.md"\ncat "$ROOT/CHANGELOG.md"' \
    $'tests/mktemp-write.bats=TREE="$(cd "$(mktemp -d)" && pwd -P)"\nprintf x >"${TREE}/CHANGELOG.md"\ngrep -q x "$TREE/CHANGELOG.md"' \
    $'tests/repo-root-read.bats=REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"\nROOT="$BATS_TEST_TMPDIR/fixture"\nprintf x > "$ROOT/CHANGELOG.md"\ncat "$REPO_ROOT/CHANGELOG.md"' \
    $'tests/unknown-root-read.bats=printf x > "$ROOT/CHANGELOG.md"\ncat "$ROOT/CHANGELOG.md"' \
    $'tests/stripped-root-read.bats=ROOT="${BATS_TEST_DIRNAME%/tests}"\ncat "$ROOT/CHANGELOG.md"' \
    $'tests/helper-root-read.bats=load helpers/sandbox\nSANDBOX="$BATS_TEST_TMPDIR/sandbox"\nprintf x > "$SANDBOX/CHANGELOG.md"\ncat "$SANDBOX/CHANGELOG.md"' \
    $'tests/unwritten-fixture-read.bats=ROOT="$BATS_TEST_TMPDIR/fixture"\nrun bash "$SCRIPTS/tool.sh" --root "$ROOT"\ncat "$ROOT/CHANGELOG.md"' \
    'tests/above-root-read.bats=cat "$PARENT/repo/CHANGELOG.md"'
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$stderr" >&2; return 1; }
  expected="$(printf '%s\n' tests/above-root-read.bats tests/helper-root-read.bats tests/repo-root-read.bats tests/stripped-root-read.bats tests/unknown-root-read.bats tests/unwritten-fixture-read.bats)"
  [ "$output" = "$expected" ] || { printf 'got:\n%s\n' "$output" >&2; return 1; }
}

@test "a command substitution fixes its directory only as a cd whose command is pwd or pwd -P, or as dirname of the suite file (a pwd path tail joins on; another cd command or a helper substitution leaves it unknown; the cd and helper rows hold with or without spaces inside the substitution)" {
  base="$(commit_base_files \
    'scripts/tool.sh=a' \
    $'tests/bare-pwd.bats=ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"\nbash "$ROOT/tool.sh"' \
    $'tests/physical-pwd.bats=ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"\nbash "$ROOT/tool.sh"' \
    $'tests/pwd-tail-other.bats=ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/other"\nbash "$ROOT/tool.sh"' \
    $'tests/pwd-tail-read.bats=ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts"\nbash "$ROOT/tool.sh"' \
    $'tests/other-command.bats=ROOT="$(cd "$BATS_TEST_DIRNAME/.." && ls)"\nbash "$ROOT/tool.sh"' \
    $'tests/spaced-bare-pwd.bats=ROOT="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"\nbash "$ROOT/tool.sh"' \
    $'tests/spaced-physical-pwd.bats=ROOT="$( cd "$BATS_TEST_DIRNAME/.." && pwd -P )"\nbash "$ROOT/tool.sh"' \
    $'tests/spaced-pwd-tail-read.bats=ROOT="$( cd "$BATS_TEST_DIRNAME/.." && pwd )/scripts"\nbash "$ROOT/tool.sh"' \
    $'tests/spaced-other-command.bats=ROOT="$( cd "$BATS_TEST_DIRNAME/.." && ls )"\nbash "$ROOT/tool.sh"' \
    $'tests/helper-substitution.bats=HELPERS="$BATS_TEST_DIRNAME/lib"\nROOT="$("$HELPERS/make.sh")"\nbash "$ROOT/tool.sh"' \
    $'tests/spaced-helper-substitution.bats=HELPERS="$BATS_TEST_DIRNAME/lib"\nROOT="$( "$HELPERS/make.sh" )"\nbash "$ROOT/tool.sh"' \
    $'tests/dirname-substitution.bats=ROOT="$(dirname "$BATS_TEST_FILENAME")"\nbash "$ROOT/tool.sh"')"
  printf 'edited\n' >> "$FIXTURE/scripts/tool.sh"
  git -C "$FIXTURE" commit -q -am tool

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$stderr" >&2; return 1; }
  expected="$(printf '%s\n' tests/helper-substitution.bats tests/other-command.bats tests/pwd-tail-read.bats tests/spaced-helper-substitution.bats tests/spaced-other-command.bats tests/spaced-pwd-tail-read.bats)"
  [ "$output" = "$expected" ] || { printf 'got:\n%s\n' "$output" >&2; return 1; }
}

@test "a temporary root populated from the real tree keeps its suite selected (a copy from the repo root or a bare repo path, a suite function that copies); a copy from another fixture does not" {
  select_on_changelog_edit \
    $'tests/copied-root.bats=REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"\nTMP="$(mktemp -d)"\ncp -R "$REPO_ROOT/." "$TMP/"\nprintf x > "$TMP/CHANGELOG.md"\ncat "$TMP/CHANGELOG.md"' \
    $'tests/bare-copy-root.bats=TMP="$(mktemp -d)"\ncp CHANGELOG.md "$TMP/"\nprintf x > "$TMP/CHANGELOG.md"\ncat "$TMP/CHANGELOG.md"' \
    $'tests/populating-function.bats=make_tree() {\n  cp -R "$REPO_ROOT/." "$1"\n}\nTMP="$(mktemp -d)"\nmake_tree "$TMP"\nprintf x > "$TMP/CHANGELOG.md"\ncat "$TMP/CHANGELOG.md"' \
    $'tests/fixture-copy.bats=TMP="$(mktemp -d)"\nprintf x > "$TMP/seed"\ncp "$TMP/seed" "$TMP/CHANGELOG.md"\nprintf x > "$TMP/CHANGELOG.md"\ncat "$TMP/CHANGELOG.md"'
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$stderr" >&2; return 1; }
  expected="$(printf '%s\n' tests/bare-copy-root.bats tests/copied-root.bats tests/populating-function.bats)"
  [ "$output" = "$expected" ] || { printf 'got:\n%s\n' "$output" >&2; return 1; }
}

@test "a suite naming a different file that shares the changed basename is not selected" {
  base="$(commit_base_files \
    'skills/alpha/SKILL.md=a' \
    'skills/beta/SKILL.md=b' \
    $'tests/reads-alpha.bats=REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"\ncat "$REPO_ROOT/skills/alpha/SKILL.md"' \
    $'tests/reads-beta.bats=REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"\ncat "$REPO_ROOT/skills/beta/SKILL.md"' \
    'tests/names-beta.bats=grep -q x skills/beta/SKILL.md' \
    'tests/longer-name.bats=cat "$RUN/child-SKILL.md"' \
    'tests/any-skill.bats=for skill in skills/*/SKILL.md; do cat "$skill"; done')"
  printf 'edited\n' >> "$FIXTURE/skills/alpha/SKILL.md"
  git -C "$FIXTURE" commit -q -am alpha

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$base" HEAD
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$stderr" >&2; return 1; }
  expected="$(printf '%s\n' tests/any-skill.bats tests/reads-alpha.bats)"
  [ "$output" = "$expected" ] || { printf 'got:\n%s\n' "$output" >&2; return 1; }
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
  several_paths="$(wc -l < "$BATS_TEST_TMPDIR/grep-calls" | tr -d ' ')"

  # The count is a property of the search, not of the change: one path costs the same.
  build_fixture
  rm -f "$BATS_TEST_TMPDIR/grep-calls"
  printf 'edited\n' >> "$FIXTURE/wiki/PR Merge Workflow.md"
  git -C "$FIXTURE" commit -q -am one
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/grep-calls" | tr -d ' ')" -eq "$several_paths" ]
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

# add_helper_suites: commit a helper chain on top of the base, then edit
# scripts/copied.sh, so that edit is the change under test.
add_helper_suites() {
  mkdir -p "$FIXTURE/tests/helpers"
  printf 'echo copied\n' > "$FIXTURE/scripts/copied.sh"
  # Copies the script into a fixture repository by name; its suite never names it.
  printf 'copy_in() { cp "$ROOT/scripts/copied.sh" "$REPO/"; }\n' > "$FIXTURE/tests/helpers/copier.sh"
  printf '# loads the copier\nload helpers/copier\n' > "$FIXTURE/tests/uses-copier.bats"
  # Reaches the copier through a second helper that sources it.
  printf '. "$BATS_TEST_DIRNAME/helpers/copier.sh"\n' > "$FIXTURE/tests/helpers/outer.sh"
  printf 'source "$BATS_TEST_DIRNAME/helpers/outer.sh"\n' > "$FIXTURE/tests/uses-outer.bats"
  # Names the script only as data it writes into a directory it made itself.
  printf 'work="$(mktemp -d)"\nprintf x > "$work/scripts/copied.sh"\n' > "$FIXTURE/tests/helpers/scratch.sh"
  printf 'load helpers/scratch\n' > "$FIXTURE/tests/uses-scratch.bats"
  # Loads a helper that names no changed file.
  printf 'noop() { :; }\n' > "$FIXTURE/tests/helpers/plain.sh"
  printf 'load helpers/plain\n' > "$FIXTURE/tests/uses-plain.bats"
  # Production code that mentions the script is not a helper.
  printf '. "$ROOT/scripts/copied.sh"\n' > "$FIXTURE/scripts/library.sh"
  printf '. "$BATS_TEST_DIRNAME/../scripts/library.sh"\n' > "$FIXTURE/tests/sources-library.bats"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m helpers
  BASE="$(git -C "$FIXTURE" rev-parse HEAD)"
  git -C "$FIXTURE" update-ref refs/remotes/origin/main "$BASE"
  printf 'edited\n' >> "$FIXTURE/scripts/copied.sh"
  git -C "$FIXTURE" commit -q -am edit
}

@test "a suite that loads a helper copying the changed script is selected, one loading no such helper is not" {
  add_helper_suites

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = $'tests/uses-copier.bats\ntests/uses-outer.bats' ] || {
    printf 'got:\n%s\n' "$output" >&2
    return 1
  }
}

@test "a helper that names the changed script only as fixture data selects no suite" {
  add_helper_suites

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'tests/uses-scratch.bats' && return 1
  printf '%s\n' "$output" | grep -qx 'tests/uses-copier.bats' || return 1
  true
}

@test "a helper mentioning the changed script only in a comment selects nothing; a helper rooted at the suite directory is not ruled out" {
  mkdir -p "$FIXTURE/tests/helpers"
  printf '# copies scripts/copied.sh somewhere, one day\nnoop() { :; }\n' > "$FIXTURE/tests/helpers/commented.sh"
  printf 'load helpers/commented\n' > "$FIXTURE/tests/uses-commented.bats"
  # The root climbs from BATS_TEST_DIRNAME, which is the loading suite's
  # directory, so it names a different tree than the helper's own location.
  printf 'ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"\ncopy_in() { cp "$ROOT/scripts/copied.sh" "$REPO/"; }\n' > "$FIXTURE/tests/helpers/rooted.sh"
  printf 'load helpers/rooted\n' > "$FIXTURE/tests/uses-rooted.bats"
  add_helper_suites

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'tests/uses-commented.bats' && return 1
  printf '%s\n' "$output" | grep -qx 'tests/uses-rooted.bats' || return 1
  true
}

@test "a failing search of the shell files a suite loads fails loudly" {
  add_helper_suites
  real_git="$(command -v git)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Fails every grep after the first, the ones that read the helper files, and
  # runs every other call for real.
  printf '#!/bin/sh\nfor argument in "$@"; do\n  if [ "$argument" = grep ]; then\n    count=$(cat "%s" 2>/dev/null || echo 0); count=$((count + 1)); echo "$count" > "%s"\n    [ "$count" -ge 2 ] && exit 128\n  fi\ndone\nexec "%s" "$@"\n' \
    "$BATS_TEST_TMPDIR/count" "$BATS_TEST_TMPDIR/count" "$real_git" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 3 ] || { echo "status $status"; return 1; }
  [ -z "$output" ]
}

# add_copy_pattern_suites: helpers that copy without naming the script, on top of
# add_helper_suites; scripts/copied.sh is the edited file.
add_copy_pattern_suites() {
  add_helper_suites
  mkdir -p "$FIXTURE/other"
  printf 'echo other\n' > "$FIXTURE/other/elsewhere.sh"
  # Copies every script of a directory by glob.
  printf 'for source_file in "$ROOT"/scripts/*.sh; do cp "$source_file" "$REPO/"; done\n' > "$FIXTURE/tests/helpers/globber.sh"
  printf 'load helpers/globber\n' > "$FIXTURE/tests/uses-globber.bats"
  # Copies every script of a directory the change does not touch.
  printf 'for source_file in "$ROOT"/other/*.sh; do cp "$source_file" "$REPO/"; done\n' > "$FIXTURE/tests/helpers/other-globber.sh"
  printf 'load helpers/other-globber\n' > "$FIXTURE/tests/uses-other-globber.bats"
  # Globs a directory held in a variable, so the change cannot be ruled out.
  printf 'for source_file in "$ROOT"/$directory/*.sh; do cp "$source_file" "$REPO/"; done\n' > "$FIXTURE/tests/helpers/unreadable-globber.sh"
  printf 'load helpers/unreadable-globber\n' > "$FIXTURE/tests/uses-unreadable-globber.bats"
  # Loops over a glob without copying the loop variable, in a helper that copies elsewhere.
  printf 'cp "$ROOT/other/elsewhere.sh" "$REPO/"\nfor entry in "$ROOT"/scripts/*.sh; do\n  echo "$entry"\ndone\n' > "$FIXTURE/tests/helpers/reading-loop.sh"
  printf 'load helpers/reading-loop\n' > "$FIXTURE/tests/uses-reading-loop.bats"
  # Copies a bare "*" tail, which names no file.
  printf 'cp "$ROOT"/* "$REPO/"\n' > "$FIXTURE/tests/helpers/bare-tail.sh"
  printf 'load helpers/bare-tail\n' > "$FIXTURE/tests/uses-bare-tail.bats"
  # Copies a glob whose stem is held in an expansion, leaving only "-*.sh".
  printf 'for hook in "${HOOK%%.sh}"-*.sh; do cp "$hook" "$REPO/"; done\n' > "$FIXTURE/tests/helpers/stemless.sh"
  printf 'load helpers/stemless\n' > "$FIXTURE/tests/uses-stemless.bats"
  # Copies a directory held in a parameter, leaving only the tail "*.sh".
  printf 'for source_file in "$source_directory"/*.sh; do cp "$source_file" "$REPO/"; done\n' > "$FIXTURE/tests/helpers/extension-only.sh"
  printf 'load helpers/extension-only\n' > "$FIXTURE/tests/uses-extension-only.bats"
  # Copies through a function parameter, in three helpers: called with the changed directory, with another one, and not at all.
  printf 'copy_directory() {\n  local source_directory="$1" destination_directory="$2"\n  for source_file in "$source_directory"/*.sh; do cp "$source_file" "$destination_directory/"; done\n}\ncopy_directory "${ROOT}/other" "$REPO/other"\ncopy_directory "${ROOT}/scripts" "$REPO/scripts"\n' > "$FIXTURE/tests/helpers/parameter-called.sh"
  printf 'load helpers/parameter-called\n' > "$FIXTURE/tests/uses-parameter-called.bats"
  printf 'copy_directory() {\n  local source_directory="$1" destination_directory="$2"\n  for source_file in "$source_directory"/*.sh; do cp "$source_file" "$destination_directory/"; done\n}\ncopy_directory "${ROOT}/other" "$REPO/other"\n' > "$FIXTURE/tests/helpers/parameter-other.sh"
  printf 'load helpers/parameter-other\n' > "$FIXTURE/tests/uses-parameter-other.bats"
  printf 'copy_directory() {\n  local source_directory="$1" destination_directory="$2"\n  for source_file in "$source_directory"/*.sh; do cp "$source_file" "$destination_directory/"; done\n}\n' > "$FIXTURE/tests/helpers/parameter-uncalled.sh"
  printf 'load helpers/parameter-uncalled\n' > "$FIXTURE/tests/uses-parameter-uncalled.bats"
  printf 'echo hooked\n' > "$FIXTURE/scripts/copied-hook.sh"
  # Copies a script and derives more copies from what it sources.
  printf 'cp "$ROOT/scripts/library.sh" "$REPO/"\ngrep -o "[a-z]*[.]sh" "$ROOT/scripts/library.sh"\n' > "$FIXTURE/tests/helpers/deriver.sh"
  printf 'load helpers/deriver\n' > "$FIXTURE/tests/uses-deriver.bats"
  # Copies the same script without deriving anything from it.
  printf 'cp "$ROOT/scripts/library.sh" "$REPO/"\n' > "$FIXTURE/tests/helpers/plain-copier.sh"
  printf 'load helpers/plain-copier\n' > "$FIXTURE/tests/uses-plain-copier.bats"
  # Runs a helper by path instead of loading it.
  printf 'run "$BATS_TEST_DIRNAME/helpers/copier.sh"\n' > "$FIXTURE/tests/invokes-copier.bats"
  printf 'run "$BATS_TEST_DIRNAME/helpers/not-tracked.sh"\n' > "$FIXTURE/tests/invokes-missing.bats"
  # Names a fixture file that copies the script; a fixture is data, not a helper.
  mkdir -p "$FIXTURE/tests/fixtures"
  printf 'cp "$ROOT/scripts/copied.sh" "$REPO/"\n' > "$FIXTURE/tests/fixtures/staged-copier.sh"
  printf 'run "$STAGE/staged-copier.sh"\n' > "$FIXTURE/tests/invokes-fixture.bats"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m copy-patterns
  BASE="$(git -C "$FIXTURE" rev-parse HEAD)"
  git -C "$FIXTURE" update-ref refs/remotes/origin/main "$BASE"
  printf 'edited again\n' >> "$FIXTURE/scripts/copied.sh"
  printf 'edited\n' >> "$FIXTURE/scripts/copied-hook.sh"
  git -C "$FIXTURE" commit -q -am edit-again
}

@test "a helper copying by a glob that covers the changed script selects its suites; a glob over another directory does not, one that cannot be read does" {
  add_copy_pattern_suites

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'tests/uses-globber.bats' || return 1
  printf '%s\n' "$output" | grep -qx 'tests/uses-unreadable-globber.bats' || return 1
  printf '%s\n' "$output" | grep -qx 'tests/uses-other-globber.bats' && return 1
  printf '%s\n' "$output" | grep -qx 'tests/uses-reading-loop.bats' && return 1
  printf '%s\n' "$output" | grep -qx 'tests/uses-bare-tail.bats' && return 1
  printf '%s\n' "$output" | grep -qx 'tests/uses-stemless.bats' && return 1
  printf '%s\n' "$output" | grep -qx 'tests/uses-extension-only.bats' && return 1
  true
}

@test "a glob over a function parameter is matched under the directories its calls pass; a call over another directory, or none, selects nothing" {
  add_copy_pattern_suites

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'tests/uses-parameter-called.bats' || return 1
  printf '%s\n' "$output" | grep -qx 'tests/uses-parameter-other.bats' && return 1
  printf '%s\n' "$output" | grep -qx 'tests/uses-parameter-uncalled.bats' && return 1
  true
}

@test "a helper that copies a script and derives copies from it is selected through that script's sourced files; a plain copy is not" {
  add_copy_pattern_suites

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'tests/uses-deriver.bats' || return 1
  printf '%s\n' "$output" | grep -qx 'tests/uses-plain-copier.bats' && return 1
  true
}

@test "a suite that runs a tracked helper by path is selected like one that loads it; a path naming no tracked helper, or only a fixture file, selects nothing" {
  add_copy_pattern_suites

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'tests/invokes-copier.bats' || return 1
  printf '%s\n' "$output" | grep -qx 'tests/invokes-missing.bats' && return 1
  printf '%s\n' "$output" | grep -qx 'tests/invokes-fixture.bats' && return 1
  true
}
