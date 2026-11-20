#!/usr/bin/env bats
#
# Every fixture below writes literal shell source into a file with a
# single-quoted `printf`, so the `$main`, `${var%...}` and `$(...)` inside those
# strings are the SUBJECT under test and must reach the file unexpanded. That is
# SC2016's whole pattern, and it fires on every one of them; file-scoped rather
# than per-line because the shape is the suite's own idiom, not an exception to
# it. Without this the oracle's output for this file is a page of known-benign
# info that a future reader has to re-adjudicate before finding a real one.
# shellcheck disable=SC2016
#
# Conformance suite for .gaia/scripts/check-main-root-derivation.sh, task
# 7.4's regression gate. It catches a hand-rolled main-root DERIVATION
# inlined into a consumer that declares no resolver function at all: three
# cheap ingredient scans (--git-common-dir, a worktrees parameter-expansion
# trim, and `worktree list --porcelain` piped to a first-record reader),
# each proven against tracked source to carry zero legitimate use outside
# the resolver.
#
# This suite IS the gate: nothing else in the repo invokes the check, so
# the "real repo" test below is what actually fails a build when a new
# hand-rolled derivation lands.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-main-root-derivation.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIRECTORY/check-main-root-derivation.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-main-root-derivation.sh
  source "$CHECK"
  FIXTURE_REPOS=()
}

teardown() {
  local fixture_directory
  for fixture_directory in "${FIXTURE_REPOS[@]:-}"; do
    [ -n "$fixture_directory" ] && rm -rf "$fixture_directory"
  done
  return 0
}

# make_fixture_repo <name>: a fresh, empty git repo under BATS_TEST_TMPDIR.
# Each test writes its own files into it before committing, so the fixture
# shape stays local to the test that needs it. Returns the repo path on
# stdout.
make_fixture_repo() {
  local name="$1"
  local directory="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$directory"
  git init -q --initial-branch=main "$directory"
  git -C "$directory" config user.email t@example.com
  git -C "$directory" config user.name T
  git -C "$directory" config commit.gpgsign false
  # Pinned for the same reason as the three above: a fixture must not take its
  # verdict from the host. `core.quotePath` defaults to true, and the non-ASCII
  # fixture below proves its repair by relying on that default, so on a host or
  # runner image whose global config sets it false that test would pass with the
  # repair reverted -- an inert guard, reporting green in exactly the case it
  # exists to catch.
  git -C "$directory" config core.quotePath true
  FIXTURE_REPOS+=("$directory")
  printf '%s' "$directory"
}

commit_fixture() {
  local directory="$1"
  git -C "$directory" add -A
  git -C "$directory" commit -q -m fixture
}

@test "structural: sourcing the script defines gaia_check_main_root_derivation with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_main_root_derivation >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# bats test_tags=whole-tree
@test "real repo: all three scans are clean against tracked source" {
  run gaia_check_main_root_derivation "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "hand-rolled --git-common-dir uses outside the resolver: 0" <<<"$output" || return 1
  grep -qF "worktrees parameter-expansion string surgery found: 0" <<<"$output" || return 1
  grep -qF "worktree list --porcelain piped to a first-record reader: 0" <<<"$output" || return 1
}

# write_case_file <repo> <case>: replaces the repo's tracked files with the one
# file the named case plants, and commits it.
write_case_file() {
  local repo="$1"
  find "$repo" -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
  case "$2" in
    common-dir)
      {
        printf '#!/usr/bin/env bash\n'
        printf 'common="$(git rev-parse --git-common-dir)"\n'
        printf 'main_root="$(dirname "$common")"\n'
      } >"$repo/consumer.sh"
      ;;
    worktrees-surgery)
      {
        printf '#!/usr/bin/env bash\n'
        printf 'common="/repo/.claude/worktrees/foo/.git"\n'
        printf 'main_root="${common%%/.git/worktrees/*}"\n'
      } >"$repo/consumer.sh"
      ;;
    porcelain-head)
      {
        printf '#!/usr/bin/env bash\n'
        printf 'main_root=$(git worktree list --porcelain | head -1 | cut -d" " -f2)\n'
      } >"$repo/consumer.sh"
      ;;
    porcelain-sed)
      {
        printf '#!/usr/bin/env bash\n'
        printf "git worktree list --porcelain \\\\\n"
        printf "  | sed -n '1p'\n"
      } >"$repo/consumer.sh"
      ;;
    comment-common-dir)
      {
        printf '#!/usr/bin/env bash\n'
        printf '# this used to call git rev-parse --git-common-dir by hand\n'
        printf 'echo hi\n'
      } >"$repo/consumer.sh"
      ;;
    markdown-common-dir)
      printf 'Resolves main via `git rev-parse --git-common-dir`.\n' >"$repo/NOTES.md"
      ;;
    test-fixture-common-dir)
      printf "execFileSync('git', ['rev-parse', '--git-common-dir']);\n" >"$repo/consumer.test.ts"
      ;;
    porcelain-full-awk)
      {
        printf '#!/usr/bin/env bash\n'
        printf "git -C \"\$main\" worktree list --porcelain | awk '\n"
        printf '  $1=="worktree"{ p=substr($0,10) }\n'
        printf "  \$1==\"\"{ if(p!=\"\") print p; p=\"\" }\n"
        printf "'\n"
      } >"$repo/consumer.sh"
      ;;
    bats-fixture)
      {
        printf '#!/usr/bin/env bats\n'
        printf '@test "plants the defect" {\n'
        printf '  common="$(git rev-parse --git-common-dir)"\n'
        printf '}\n'
      } >"$repo/plant.bats"
      ;;
    clean) printf '#!/usr/bin/env bash\necho hi\n' >"$repo/consumer.sh" ;;
    *)
      echo "write_case_file: unknown case $2" >&2
      return 1
      ;;
  esac
  commit_fixture "$repo"
}

# bats test_tags=protected
@test "fixture: a bare --git-common-dir derivation in a consumer fails" {
  local repo row case_name expected_line
  repo="$(make_fixture_repo bad-derivations)"
  for row in \
    'common-dir|hand-rolled --git-common-dir uses outside the resolver: 1' \
    'worktrees-surgery|worktrees parameter-expansion string surgery found: 1' \
    'porcelain-head|worktree list --porcelain piped to a first-record reader: 1' \
    'porcelain-sed|worktree list --porcelain piped to a first-record reader: 1'; do
    IFS='|' read -r case_name expected_line <<<"$row"
    write_case_file "$repo" "$case_name"
    run gaia_check_main_root_derivation "$repo"
    [ "$status" -eq 1 ] || { echo "case $case_name: status $status"; return 1; }
    grep -qF "$expected_line" <<<"$output" || { echo "case $case_name: missing '$expected_line'"; return 1; }
    grep -qF "consumer.sh" <<<"$output" || { echo "case $case_name: consumer.sh not named"; return 1; }
  done
}

@test "fixture: a mention in a comment, markdown, test, bats fixture or full parse does not fail" {
  local repo case_name
  repo="$(make_fixture_repo benign-mentions)"
  for case_name in comment-common-dir markdown-common-dir test-fixture-common-dir porcelain-full-awk bats-fixture clean; do
    write_case_file "$repo" "$case_name"
    run gaia_check_main_root_derivation "$repo"
    [ "$status" -eq 0 ] || { echo "case $case_name: status $status"; return 1; }
    grep -qF "hand-rolled --git-common-dir uses outside the resolver: 0" <<<"$output" || { echo "case $case_name: common-dir count not 0"; return 1; }
    grep -qF "worktrees parameter-expansion string surgery found: 0" <<<"$output" || { echo "case $case_name: surgery count not 0"; return 1; }
    grep -qF "worktree list --porcelain piped to a first-record reader: 0" <<<"$output" || { echo "case $case_name: porcelain count not 0"; return 1; }
  done
}

@test "fixture: the fast lib is exempt, and the same line in a sibling scripts file fails" {
  local repo
  repo="$(make_fixture_repo companion-exemption)"
  mkdir -p "$repo/.gaia/scripts"
  printf 'raw="$(git rev-parse --git-common-dir)"\n' >"$repo/.gaia/scripts/rate-limit-main-root-probe-lib.sh"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "hand-rolled --git-common-dir uses outside the resolver: 0" <<<"$output" || return 1

  printf 'raw="$(git rev-parse --git-common-dir)"\n' >"$repo/.gaia/scripts/tree-root-helper.sh"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "hand-rolled --git-common-dir uses outside the resolver: 1" <<<"$output" || return 1
  grep -qF ".gaia/scripts/tree-root-helper.sh" <<<"$output" || return 1
}

