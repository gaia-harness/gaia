#!/usr/bin/env bats
# Tests for .gaia/scripts/worktree-removal-check.sh, the stop that runs before
# a merged worktree is removed.
#
# Every case builds a throwaway repository under BATS_TEST_TMPDIR (a bare
# origin, a main checkout, and a linked worktree on a pushed branch) and runs
# the script against the worktree. The script is judged on what it prints and
# its exit status; no case touches the real repository.
#
# The red cases come first in each group: a script that always said CLEAR would
# pass every green case, so each refusal is driven by the state that must stop
# it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  CHECK="${WORKTREE_REMOVAL_CHECK:-$REPO_ROOT/.gaia/scripts/worktree-removal-check.sh}"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="Fixture" GIT_AUTHOR_EMAIL="fixture@example.invalid"
  export GIT_COMMITTER_NAME="Fixture" GIT_COMMITTER_EMAIL="fixture@example.invalid"
  BRANCH=feat-tree
  make_tree "$BATS_TEST_TMPDIR/fixture"
}

# make_tree <dir>: sets MAIN and TREE. The worktree holds BRANCH, which is
# pushed with its upstream set and sits level with its remote-tracking ref.
make_tree() {
  local dir=$1
  mkdir -p "$dir" || return 1
  git init -q --bare -b main "$dir/origin.git" || return 1
  MAIN="$dir/main-checkout"
  git init -q -b main "$MAIN" || return 1
  git -C "$MAIN" remote add origin "$dir/origin.git" || return 1
  printf 'base\n' >"$MAIN/base" || return 1
  git -C "$MAIN" add base || return 1
  git -C "$MAIN" commit -q -m base || return 1
  git -C "$MAIN" push -q -u origin main 2>/dev/null || return 1
  git -C "$MAIN" branch "$BRANCH" || return 1
  git -C "$MAIN" push -q -u origin "$BRANCH" 2>/dev/null || return 1
  TREE="$dir/tree"
  git -C "$MAIN" worktree add -q "$TREE" "$BRANCH" || return 1
}

check_tree() {
  run bash "$CHECK" --tree "$TREE"
}

@test "a clean pushed tree is CLEAR" {
  check_tree
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ "$output" = "CLEAR" ] || { printf '%s\n' "$output"; return 1; }
}

@test "an empty .gaia-merge directory is CLEAR because git ignores empty directories" {
  mkdir "$TREE/.gaia-merge"
  check_tree
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

# bats test_tags=protected
@test "DIRTY: a modified tracked file, an untracked file and a populated .gaia-merge each read DIRTY with the Next step line" {
  # a populated .gaia-merge is an ordinary untracked directory
  mkdir "$TREE/.gaia-merge"
  printf 'p\n' >"$TREE/.gaia-merge/a.patch"
  check_tree
  [ "$status" -eq 1 ] || { printf 'case gaia-merge: %s\n' "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | head -n 1)" = "DIRTY" ] || { printf 'case gaia-merge: %s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "?? .gaia-merge/" || { printf 'case gaia-merge: %s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fxq "PENDING" && { printf 'case gaia-merge: %s\n' "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | grep -c '^Next step:')" -eq 1 ] || { printf 'case gaia-merge: %s\n' "$output"; return 1; }
  rm -rf "$TREE/.gaia-merge"

  # a modified tracked file names the removal commands
  printf 'edited\n' >>"$TREE/base"
  check_tree
  [ "$status" -eq 1 ] || { printf 'case modified: %s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fxq "DIRTY" || { printf 'case modified: %s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq " M base" || { printf 'case modified: %s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "git worktree remove --force $TREE" || { printf 'case modified: %s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "git branch -D $BRANCH" || { printf 'case modified: %s\n' "$output"; return 1; }
  git -C "$TREE" checkout -q -- base

  # an untracked, non-ignored file
  printf 'new\n' >"$TREE/untracked.txt"
  check_tree
  [ "$status" -eq 1 ] || { printf 'case untracked: %s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "?? untracked.txt" || { printf 'case untracked: %s\n' "$output"; return 1; }
}

@test "ignored paths alone are CLEAR: .gaia-backup and node_modules" {
  mkdir "$TREE/.gaia-backup"
  printf 'x\n' >"$TREE/.gaia-backup/old.txt"
  printf '.gaia-backup/\n' >>"$MAIN/.git/info/exclude"
  check_tree
  [ "$status" -eq 0 ] || { printf 'case gaia-backup: %s\n' "$output"; return 1; }

  printf 'node_modules/\n' >>"$MAIN/.git/info/exclude"
  mkdir "$TREE/node_modules"
  printf 'x\n' >"$TREE/node_modules/pkg.js"
  check_tree
  [ "$status" -eq 0 ] || { printf 'case node_modules: %s\n' "$output"; return 1; }
}

@test "refusal: no --tree or a non-work-tree path exits 2" {
  run bash "$CHECK"
  [ "$status" -eq 2 ] || { printf 'case no --tree: %s\n' "$output"; return 1; }
  mkdir "$BATS_TEST_TMPDIR/plain"
  run bash "$CHECK" --tree "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 2 ] || { printf 'case non-work-tree: %s\n' "$output"; return 1; }
}

# bats test_tags=protected
@test "failing state: a commit ahead of an existing upstream reports Unpushed" {
  printf 'more\n' >"$TREE/more"
  git -C "$TREE" add more
  git -C "$TREE" commit -q -m more
  check_tree
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fxq "Unpushed: 1 commit(s) ahead of origin/$BRANCH" || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fxq "DIRTY" || { printf '%s\n' "$output"; return 1; }
}

@test "the same commit with the upstream ref deleted is CLEAR" {
  printf 'more\n' >"$TREE/more"
  git -C "$TREE" add more
  git -C "$TREE" commit -q -m more
  git -C "$MAIN" update-ref -d "refs/remotes/origin/$BRANCH"
  check_tree
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}
