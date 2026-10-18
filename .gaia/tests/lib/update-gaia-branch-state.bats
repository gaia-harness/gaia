#!/usr/bin/env bats
# update-gaia-branch-state.sh: an existing update branch is classified from its
# own state (its holding worktree, or its committed .gaia/VERSION), never from
# the main checkout's. Fixtures are real repositories with real linked
# worktrees, each branch carrying a committed .gaia/VERSION. Every guarded
# state has a red twin: the same fixture one step away from the guarded state.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/update-gaia-branch-state.sh"
  TAG='v2.1.0'
  BASELINE='2.0.0'
  LATEST='2.1.0'
  MAIN="$BATS_TEST_TMPDIR/main"
  mkdir -p "$MAIN/.gaia"
  git init -q -b main "$MAIN"
  printf '%s\n' "$BASELINE" > "$MAIN/.gaia/VERSION"
  commit_in "$MAIN" 'baseline' 1700000000
  MAIN="$(cd "$MAIN" && pwd -P)"
}

# Commits everything in tree `$1` with message `$2` at epoch `$3`.
commit_in() {
  git -C "$1" add -A
  GIT_AUTHOR_DATE="@$3" GIT_COMMITTER_DATE="@$3" \
    git -C "$1" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false \
    commit -q --allow-empty -m "$2"
}

# A branch `$1` created from main with version `$2` committed on it at epoch
# `$3`. By default a worktree under main's .claude/worktrees holds it and HOLDER
# is that path; with `$4` = free the worktree is removed and HOLDER is empty.
make_branch() {
  local branch="$1" version="$2" epoch="$3" mode="${4:-held}"
  HOLDER="$MAIN/.claude/worktrees/${branch//\//+}"
  git -C "$MAIN" worktree add -q -b "$branch" "$HOLDER" main
  printf '%s\n' "$version" > "$HOLDER/.gaia/VERSION"
  commit_in "$HOLDER" "version $version" "$epoch"
  if [ "$mode" != held ]; then
    git -C "$MAIN" worktree remove --force "$HOLDER"
    HOLDER=''
  else
    HOLDER="$(cd "$HOLDER" && pwd -P)"
  fi
}

# Runs the script with working directory `$1` and the remaining arguments.
run_script_in() {
  local directory="$1"
  shift
  run bash -c 'cd "$1" || exit 99; shift; exec bash "$0" "$@"' "$SCRIPT" "$directory" "$@"
}

@test "classify: no matching branch is NONE, and a branch for another tag is NONE" {
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  [ "$status" -eq 0 ]
  [ "$output" = 'NONE' ]
  make_branch 'update/v9.9.9-20260101-0000' "$BASELINE" 1700000100
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  [ "$status" -eq 0 ]
  [ "$output" = 'NONE' ]
}

@test "classify: a held branch still at the baseline resumes in its worktree" {
  make_branch 'update/v2.1.0-20260101-0000' "$BASELINE" 1700000100
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  [ "$status" -eq 0 ]
  [ "$output" = "RESUME_IN_WORKTREE update/v2.1.0-20260101-0000 $HOLDER" ]
}

@test "classify: a version written but uncommitted in the holder is APPLIED_UNCOMMITTED, never a resume" {
  make_branch 'update/v2.1.0-20260101-0000' "$BASELINE" 1700000100
  printf '%s\n' "$LATEST" > "$HOLDER/.gaia/VERSION"
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  [ "$status" -eq 0 ]
  [ "$output" = "APPLIED_UNCOMMITTED update/v2.1.0-20260101-0000 $HOLDER" ]
  printf '%s\n' "$output" | grep -q '^RESUME' && return 1
  # Red twin: restore the baseline in the working tree and it resumes.
  printf '%s\n' "$BASELINE" > "$HOLDER/.gaia/VERSION"
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  [ "$output" = "RESUME_IN_WORKTREE update/v2.1.0-20260101-0000 $HOLDER" ]
}

@test "classify: a committed version is COMMITTED with the holder path, or - without one" {
  make_branch 'update/v2.1.0-20260101-0000' "$LATEST" 1700000100
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  [ "$status" -eq 0 ]
  [ "$output" = "COMMITTED update/v2.1.0-20260101-0000 $HOLDER" ]
  git -C "$MAIN" worktree remove --force "$HOLDER"
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  [ "$status" -eq 0 ]
  [ "$output" = 'COMMITTED update/v2.1.0-20260101-0000 -' ]
}

@test "classify: no holder and the branch at the baseline is RESUME_ADD_WORKTREE" {
  make_branch 'update/v2.1.0-20260101-0000' "$BASELINE" 1700000100 free
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  [ "$status" -eq 0 ]
  [ "$output" = 'RESUME_ADD_WORKTREE update/v2.1.0-20260101-0000' ]
}

@test "classify: the main checkout's own version file is never read" {
  make_branch 'update/v2.1.0-20260101-0000' "$BASELINE" 1700000100
  printf '%s\n' "$LATEST" > "$MAIN/.gaia/VERSION"
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  [ "$output" = "RESUME_IN_WORKTREE update/v2.1.0-20260101-0000 $HOLDER" ]
  # The other direction: main at the baseline, the branch committed at LATEST.
  printf '%s\n' "$BASELINE" > "$MAIN/.gaia/VERSION"
  printf '%s\n' "$LATEST" > "$HOLDER/.gaia/VERSION"
  commit_in "$HOLDER" 'bump' 1700000200
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  [ "$output" = "COMMITTED update/v2.1.0-20260101-0000 $HOLDER" ]
}

@test "classify: the most recently committed branch wins, and --branch names exactly one" {
  make_branch 'update/v2.1.0-20260101-0000' "$LATEST" 1700000100
  make_branch 'update/v2.1.0-20260102-0000' "$BASELINE" 1700000900 free
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  [ "$output" = 'RESUME_ADD_WORKTREE update/v2.1.0-20260102-0000' ]
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST" --branch update/v2.1.0-20260101-0000
  case "$output" in
    'COMMITTED update/v2.1.0-20260101-0000 '*) ;;
    *) echo "unexpected: $output" >&2; return 1 ;;
  esac
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST" --branch update/v2.1.0-nope
  [ "$output" = 'NONE' ]
}

@test "classify: run from inside the holding worktree gives the same answer as from main" {
  make_branch 'update/v2.1.0-20260101-0000' "$BASELINE" 1700000100
  run_script_in "$MAIN" classify --tag "$TAG" --latest "$LATEST"
  from_main="$output"
  run_script_in "$HOLDER" classify --tag "$TAG" --latest "$LATEST"
  [ "$status" -eq 0 ]
  [ "$output" = "$from_main" ]
  [ "$output" = "RESUME_IN_WORKTREE update/v2.1.0-20260101-0000 $HOLDER" ]
}

@test "add-worktree: adds a worktree on the existing branch without creating a branch" {
  make_branch 'update/v2.1.0-20260101-0000' "$BASELINE" 1700000100 free
  before="$(git -C "$MAIN" for-each-ref --format='%(refname)')"
  run_script_in "$MAIN" add-worktree --branch update/v2.1.0-20260101-0000
  [ "$status" -eq 0 ]
  expected="$MAIN/.claude/worktrees/update+v2.1.0-20260101-0000"
  [ "$output" = "ADDED $expected" ]
  [ -d "$expected" ]
  git -C "$MAIN" worktree list --porcelain | grep -qxF "worktree $expected"
  git -C "$MAIN" worktree list --porcelain | grep -qxF 'branch refs/heads/update/v2.1.0-20260101-0000'
  [ "$(git -C "$MAIN" for-each-ref --format='%(refname)')" = "$before" ]
}

@test "add-worktree: runs from inside another worktree and still lands under main" {
  make_branch 'update/v2.1.0-20260101-0000' "$BASELINE" 1700000100 free
  make_branch 'update/v2.1.0-20260102-0000' "$BASELINE" 1700000200
  run_script_in "$HOLDER" add-worktree --branch update/v2.1.0-20260101-0000
  [ "$status" -eq 0 ]
  [ "$output" = "ADDED $MAIN/.claude/worktrees/update+v2.1.0-20260101-0000" ]
}

@test "add-worktree: refuses a branch a worktree already holds" {
  make_branch 'update/v2.1.0-20260101-0000' "$BASELINE" 1700000100
  before="$(git -C "$MAIN" worktree list --porcelain)"
  run_script_in "$MAIN" add-worktree --branch update/v2.1.0-20260101-0000
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^ADDED' && return 1
  [ "$(git -C "$MAIN" worktree list --porcelain)" = "$before" ]
}

@test "add-worktree: refuses when the target path already exists" {
  make_branch 'update/v2.1.0-20260101-0000' "$BASELINE" 1700000100 free
  mkdir -p "$MAIN/.claude/worktrees/update+v2.1.0-20260101-0000"
  before="$(git -C "$MAIN" worktree list --porcelain)"
  run_script_in "$MAIN" add-worktree --branch update/v2.1.0-20260101-0000
  [ "$status" -eq 1 ]
  [ "$(git -C "$MAIN" worktree list --porcelain)" = "$before" ]
}

@test "add-worktree: refuses a branch that does not exist" {
  run_script_in "$MAIN" add-worktree --branch update/v2.1.0-nope
  [ "$status" -eq 1 ]
  [ ! -e "$MAIN/.claude/worktrees" ]
}

@test "usage errors and a working directory outside a repository exit 2" {
  run_script_in "$MAIN" bogus
  [ "$status" -eq 2 ]
  run_script_in "$MAIN"
  [ "$status" -eq 2 ]
  run_script_in "$MAIN" classify --latest "$LATEST"
  [ "$status" -eq 2 ]
  run_script_in "$MAIN" classify --tag "$TAG"
  [ "$status" -eq 2 ]
  run_script_in "$MAIN" classify --tag "$TAG" --latest
  [ "$status" -eq 2 ]
  run_script_in "$MAIN" add-worktree
  [ "$status" -eq 2 ]
  mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
  run_script_in "$BATS_TEST_TMPDIR/not-a-repo" classify --tag "$TAG" --latest "$LATEST"
  [ "$status" -eq 2 ]
  run_script_in "$BATS_TEST_TMPDIR/not-a-repo" add-worktree --branch x
  [ "$status" -eq 2 ]
}
