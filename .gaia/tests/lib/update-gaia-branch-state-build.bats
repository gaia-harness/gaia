#!/usr/bin/env bats
# update-gaia-branch-state.sh classify with a build record: on a local run the
# update is recorded once .gaia/VERSION-dev holds the target build id, on a
# release run once the file is gone, because a local sync often keeps the same
# .gaia/VERSION. Fixtures are real repositories with real linked worktrees.
# Every guarded state has a red twin: the same fixture one step from it.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/update-gaia-branch-state.sh"
  VERSION='2.2.0'
  PREVIOUS_BUILD='dev.aaaaaaaaaaaa'
  TARGET_BUILD='dev.bbbbbbbbbbbb'
  DEV_TAG="v2.2.0-dev.bbbbbbbbbbbb"
  DEV_BRANCH="update/$DEV_TAG-2026-10-27-1200"
  RELEASE_BRANCH='update/v2.2.0-2026-10-26-0900'
  MAIN="$BATS_TEST_TMPDIR/main"
  mkdir -p "$MAIN/.gaia"
  git init -q -b main "$MAIN"
  printf '%s\n' "$VERSION" > "$MAIN/.gaia/VERSION"
  printf '%s\n' "$PREVIOUS_BUILD" > "$MAIN/.gaia/VERSION-dev"
  commit_in "$MAIN" 'baseline with a recorded local build' 1700000000
  MAIN="$(cd "$MAIN" && pwd -P)"
}

# Commits everything in tree `$1` with message `$2` at epoch `$3`.
commit_in() {
  git -C "$1" add -A
  GIT_AUTHOR_DATE="@$3" GIT_COMMITTER_DATE="@$3" \
    git -C "$1" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false \
    commit -q --allow-empty -m "$2"
}

# A branch `$1` from main at epoch `$4`. `$2` is the version committed on it and
# `$3` the build record committed on it: a build id, `none` to delete the file,
# or `keep` to leave main's record. `$5` = free removes the worktree holding it;
# otherwise HOLDER is that worktree's path.
make_branch() {
  local branch="$1" version="$2" build="$3" epoch="$4" mode="${5:-held}"
  HOLDER="$MAIN/.claude/worktrees/${branch//\//+}"
  git -C "$MAIN" worktree add -q -b "$branch" "$HOLDER" main
  printf '%s\n' "$version" > "$HOLDER/.gaia/VERSION"
  case "$build" in
    keep) ;;
    none) rm -f "$HOLDER/.gaia/VERSION-dev" ;;
    *) printf '%s\n' "$build" > "$HOLDER/.gaia/VERSION-dev" ;;
  esac
  commit_in "$HOLDER" "update on $branch" "$epoch"
  if [ "$mode" = free ]; then
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

classify_local() {
  run_script_in "$MAIN" classify --tag "$DEV_TAG" --latest "$VERSION" --build "$TARGET_BUILD"
}

classify_release() {
  run_script_in "$MAIN" classify --tag v2.2.0 --latest "$1"
}

@test "local run: a same-version branch still holding the previous build resumes, a recorded one is committed" {
  make_branch "$DEV_BRANCH" "$VERSION" keep 1700000100
  classify_local
  [ "$status" -eq 0 ]
  [ "$output" = "RESUME_IN_WORKTREE $DEV_BRANCH $HOLDER" ]
  # Red twin: the same branch with the target build committed.
  printf '%s\n' "$TARGET_BUILD" > "$HOLDER/.gaia/VERSION-dev"
  commit_in "$HOLDER" 'record the build' 1700000200
  classify_local
  [ "$output" = "COMMITTED $DEV_BRANCH $HOLDER" ]
}

@test "local run: the target build written but uncommitted in the holder is APPLIED_UNCOMMITTED" {
  make_branch "$DEV_BRANCH" "$VERSION" keep 1700000100
  printf '%s\n' "$TARGET_BUILD" > "$HOLDER/.gaia/VERSION-dev"
  classify_local
  [ "$status" -eq 0 ]
  [ "$output" = "APPLIED_UNCOMMITTED $DEV_BRANCH $HOLDER" ]
  # Red twin: restore the previous build in the working tree and it resumes.
  printf '%s\n' "$PREVIOUS_BUILD" > "$HOLDER/.gaia/VERSION-dev"
  classify_local
  [ "$output" = "RESUME_IN_WORKTREE $DEV_BRANCH $HOLDER" ]
}

@test "local run: a committed record is COMMITTED with the holder path, or - without one" {
  make_branch "$DEV_BRANCH" "$VERSION" "$TARGET_BUILD" 1700000100
  classify_local
  [ "$status" -eq 0 ]
  [ "$output" = "COMMITTED $DEV_BRANCH $HOLDER" ]
  git -C "$MAIN" worktree remove --force "$HOLDER"
  classify_local
  [ "$output" = "COMMITTED $DEV_BRANCH -" ]
}

@test "local run: no holder and the previous build still recorded is RESUME_ADD_WORKTREE" {
  make_branch "$DEV_BRANCH" "$VERSION" keep 1700000100 free
  classify_local
  [ "$status" -eq 0 ]
  [ "$output" = "RESUME_ADD_WORKTREE $DEV_BRANCH" ]
}

@test "local run: the right version with no build file is not recorded" {
  make_branch "$DEV_BRANCH" "$VERSION" none 1700000100
  classify_local
  [ "$output" = "RESUME_IN_WORKTREE $DEV_BRANCH $HOLDER" ]
}

@test "release run after a local sync at the same version: recorded means the build file is gone" {
  make_branch "$RELEASE_BRANCH" "$VERSION" keep 1700000100
  classify_release "$VERSION"
  [ "$status" -eq 0 ]
  [ "$output" = "RESUME_IN_WORKTREE $RELEASE_BRANCH $HOLDER" ]
  rm "$HOLDER/.gaia/VERSION-dev"
  classify_release "$VERSION"
  [ "$output" = "APPLIED_UNCOMMITTED $RELEASE_BRANCH $HOLDER" ]
  commit_in "$HOLDER" 'remove the build record' 1700000200
  classify_release "$VERSION"
  [ "$output" = "COMMITTED $RELEASE_BRANCH $HOLDER" ]
}

@test "release run with a newer version interrupted before the build file removal resumes" {
  make_branch "$RELEASE_BRANCH" "$VERSION" keep 1700000100
  printf '%s\n' '2.3.0' > "$HOLDER/.gaia/VERSION"
  classify_release '2.3.0'
  [ "$output" = "RESUME_IN_WORKTREE $RELEASE_BRANCH $HOLDER" ]
  # Red twin: once the file is removed too, the update is applied.
  rm "$HOLDER/.gaia/VERSION-dev"
  classify_release '2.3.0'
  [ "$output" = "APPLIED_UNCOMMITTED $RELEASE_BRANCH $HOLDER" ]
}

@test "a project that never had a build file classifies on the version alone" {
  git -C "$MAIN" rm -q .gaia/VERSION-dev
  commit_in "$MAIN" 'drop the build record' 1700000050
  make_branch "$RELEASE_BRANCH" '2.1.0' keep 1700000100
  classify_release "$VERSION"
  [ "$output" = "RESUME_IN_WORKTREE $RELEASE_BRANCH $HOLDER" ]
  printf '%s\n' "$VERSION" > "$HOLDER/.gaia/VERSION"
  classify_release "$VERSION"
  [ "$output" = "APPLIED_UNCOMMITTED $RELEASE_BRANCH $HOLDER" ]
  commit_in "$HOLDER" 'bump' 1700000200
  classify_release "$VERSION"
  [ "$output" = "COMMITTED $RELEASE_BRANCH $HOLDER" ]
}

@test "the existing branch-state suite is untouched" {
  git -C "$REPO_ROOT" diff --quiet -- .gaia/tests/lib/update-gaia-branch-state.bats
}

@test "a malformed --build is a usage error" {
  run_script_in "$MAIN" classify --tag "$DEV_TAG" --latest "$VERSION" --build 'dev.bbbbbbbbbbbb/x'
  [ "$status" -eq 2 ]
  run_script_in "$MAIN" classify --tag "$DEV_TAG" --latest "$VERSION" --build 1234
  [ "$status" -eq 2 ]
  run_script_in "$MAIN" classify --tag "$DEV_TAG" --latest "$VERSION" --build
  [ "$status" -eq 2 ]
}

@test "release lookup skips a local-sync branch, the dev lookup still finds it" {
  make_branch "$DEV_BRANCH" "$VERSION" "$TARGET_BUILD" 1700000100
  classify_release "$VERSION"
  [ "$status" -eq 0 ]
  [ "$output" = 'NONE' ]
  classify_local
  [ "$output" = "COMMITTED $DEV_BRANCH $HOLDER" ]
}

@test "release lookup takes the release branch even beside a newer local-sync branch" {
  make_branch "$RELEASE_BRANCH" '2.1.0' none 1700000100 free
  make_branch "$DEV_BRANCH" "$VERSION" "$TARGET_BUILD" 1700000900
  classify_release "$VERSION"
  [ "$output" = "RESUME_ADD_WORKTREE $RELEASE_BRANCH" ]
  classify_local
  [ "$output" = "COMMITTED $DEV_BRANCH $HOLDER" ]
}
