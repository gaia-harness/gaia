#!/usr/bin/env bats
# update-gaia-pull.sh: the guarded fast-forward of the main checkout's default
# branch. Every case runs against a bare origin and clones in temp dirs, so no
# network is touched. Each refusal asserts the tree is exactly as it was.
#
# Assertion style: .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/update-gaia-pull.sh"
  export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.com
  export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.com
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  TREE="$BATS_TEST_TMPDIR/tree"
  PUSHER="$BATS_TEST_TMPDIR/pusher"
}

# A bare origin whose only branch is $1 (default main), seeded with version
# 2.0.3 and a lockfile, plus the checkout under test cloned from it.
make_origin_and_tree() {
  local branch="${1:-main}"
  git init --quiet --bare --initial-branch="$branch" "$ORIGIN"
  git clone --quiet "$ORIGIN" "$PUSHER" 2>/dev/null
  git -C "$PUSHER" checkout --quiet -b "$branch"
  mkdir -p "$PUSHER/.gaia"
  echo 2.0.3 >"$PUSHER/.gaia/VERSION"
  echo 'lock: one' >"$PUSHER/pnpm-lock.yaml"
  git -C "$PUSHER" add -A
  git -C "$PUSHER" commit --quiet -m seed
  git -C "$PUSHER" push --quiet origin "$branch" 2>/dev/null
  git clone --quiet "$ORIGIN" "$TREE" 2>/dev/null
}

# Pushes a commit to origin's $2 branch (default main) that sets the version to
# $1 and, when $3 is `lock`, changes the lockfile.
advance_origin() {
  local version="$1" branch="${2:-main}" with_lock="${3:-}"
  echo "$version" >"$PUSHER/.gaia/VERSION"
  [ "$with_lock" = lock ] && echo "lock: $version" >"$PUSHER/pnpm-lock.yaml"
  git -C "$PUSHER" commit --quiet -am "release $version"
  git -C "$PUSHER" push --quiet origin "$branch" 2>/dev/null
}

tree_snapshot() {
  {
    git -C "$TREE" rev-parse HEAD
    git -C "$TREE" symbolic-ref --quiet HEAD
    git -C "$TREE" status --porcelain
    git -C "$TREE" diff HEAD
    git -C "$TREE" stash list
  } 2>&1
}

# Prints a table case's label so a failing case names itself in the bats
# output, and removes the repositories the previous case left.
fresh_case() {
  printf 'case: %s\n' "$1"
  rm -rf "$ORIGIN" "$TREE" "$PUSHER" "$BATS_TEST_TMPDIR/linked"
}

# Builds the main-branch origin, pusher and tree once per table test and saves
# a copy that pull_case restores for each case.
build_pristine() {
  PRISTINE="$BATS_TEST_TMPDIR/pristine"
  make_origin_and_tree
  mkdir -p "$PRISTINE"
  cp -R "$ORIGIN" "$TREE" "$PUSHER" "$PRISTINE"/
}

# Starts a case on a fresh copy of the main-branch origin, pusher and tree.
# The copies sit at the original paths, so the clones' origin URLs still hold.
pull_case() {
  fresh_case "$1"
  cp -R "$PRISTINE/origin.git" "$ORIGIN"
  cp -R "$PRISTINE/tree" "$TREE"
  cp -R "$PRISTINE/pusher" "$PUSHER"
}

# A refusal names its code, gives both lines, exits 1 and leaves the tree and
# the stash list exactly as they were.
assert_refused() {
  local code="$1" before="$2"
  [ "$status" -eq 1 ]
  [ "$(sed -n 1p <<<"$output")" = "PULL_REFUSED $code" ]
  grep -q '^Reason: .' <<<"$output"
  grep -q '^Next step: .' <<<"$output"
  [ "$(tree_snapshot)" = "$before" ]
  [ -z "$(git -C "$TREE" stash list)" ]
}

@test "check reports PULL_READY with the default branch, never fetches and ignores untracked files" {
  build_pristine

  pull_case 'check on a clean default branch prints PULL_READY main'
  run bash "$SCRIPT" check --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$output" = "PULL_READY main" ]

  fresh_case 'check reads the default branch from a clone whose origin has only master and no origin/HEAD'
  make_origin_and_tree master
  git -C "$TREE" remote set-head origin -d >/dev/null
  git -C "$TREE" show-ref --verify --quiet refs/remotes/origin/HEAD && return 1
  run bash "$SCRIPT" check --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$output" = "PULL_READY master" ]

  pull_case 'check never touches the network'
  advance_origin 2.0.4
  local origin_head_before
  origin_head_before="$(git -C "$TREE" rev-parse origin/main)"
  run bash "$SCRIPT" check --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TREE" rev-parse origin/main)" = "$origin_head_before" ]

  pull_case 'check ignores an untracked file'
  echo scratch >"$TREE/untracked.txt"
  run bash "$SCRIPT" check --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$output" = "PULL_READY main" ]
}

@test "pull fast-forwards and prints versions and the lockfile verdict in each origin shape" {
  build_pristine

  pull_case 'pull fast-forwards HEAD to origin'
  advance_origin 2.0.4
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TREE" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse main)" ]

  pull_case 'pull prints the old and new version'
  advance_origin 2.0.4
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<<"$output")" = "PULLED 2.0.3 2.0.4" ]

  pull_case 'pull prints LOCKFILE_CHANGED yes when origin changed pnpm-lock.yaml'
  advance_origin 2.0.4 main lock
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p <<<"$output")" = "LOCKFILE_CHANGED yes" ]

  pull_case 'pull prints LOCKFILE_CHANGED no when origin left pnpm-lock.yaml alone'
  advance_origin 2.0.4
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p <<<"$output")" = "LOCKFILE_CHANGED no" ]

  pull_case 'pull counts a lockfile that appears on origin as changed'
  git -C "$PUSHER" rm --quiet pnpm-lock.yaml
  git -C "$PUSHER" commit --quiet -m "drop lock"
  git -C "$PUSHER" push --quiet origin main 2>/dev/null
  git -C "$TREE" pull --quiet --ff-only 2>/dev/null
  echo 'lock: back' >"$PUSHER/pnpm-lock.yaml"
  git -C "$PUSHER" add pnpm-lock.yaml
  git -C "$PUSHER" commit --quiet -m "restore lock"
  git -C "$PUSHER" push --quiet origin main 2>/dev/null
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p <<<"$output")" = "LOCKFILE_CHANGED yes" ]

  fresh_case 'pull works from a clone with only master and no origin/HEAD'
  make_origin_and_tree master
  git -C "$TREE" remote set-head origin -d >/dev/null
  advance_origin 2.0.4 master
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<<"$output")" = "PULLED 2.0.3 2.0.4" ]

  pull_case 'pull proceeds with an untracked file present and leaves it alone'
  advance_origin 2.0.4
  echo scratch >"$TREE/untracked.txt"
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(cat "$TREE/untracked.txt")" = "scratch" ]

  pull_case 'pull when already current prints the same version twice and LOCKFILE_CHANGED no'
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'PULLED 2.0.3 2.0.3\nLOCKFILE_CHANGED no')" ]
}

# bats test_tags=protected
@test "pull and check refuse each unsafe tree state untouched, a local-only commit is not a divergence, and a failed fetch leaves the tree alone" {
  build_pristine

  pull_case 'refuses on a non-default branch and leaves the tree untouched'
  git -C "$TREE" checkout --quiet -b feature
  advance_origin 2.0.4
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" pull --tree "$TREE"
  assert_refused not-default-branch "$before"

  pull_case 'refuses on a detached HEAD'
  git -C "$TREE" checkout --quiet --detach
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" pull --tree "$TREE"
  assert_refused not-default-branch "$before"

  pull_case 'check refuses with a modified tracked file'
  echo edited >>"$TREE/pnpm-lock.yaml"
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" check --tree "$TREE"
  assert_refused uncommitted-changes "$before"

  pull_case 'refuses with a staged change and leaves the index untouched'
  advance_origin 2.0.4
  echo staged >"$TREE/new-file.txt"
  git -C "$TREE" add new-file.txt
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" pull --tree "$TREE"
  assert_refused uncommitted-changes "$before"

  pull_case 'refuses against a linked worktree path'
  git -C "$TREE" worktree add --quiet -b side "$BATS_TEST_TMPDIR/linked" 2>/dev/null
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" pull --tree "$BATS_TEST_TMPDIR/linked"
  assert_refused worktree "$before"

  pull_case 'a local commit origin lacks, with origin otherwise unchanged, is not a divergence'
  echo local >"$TREE/local.txt"
  git -C "$TREE" add local.txt
  git -C "$TREE" commit --quiet -m "local only"
  local head_before
  head_before="$(git -C "$TREE" rev-parse HEAD)"
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TREE" rev-parse HEAD)" = "$head_before" ]

  pull_case 'a failing fetch prints PULL_FAILED, exits 1 and leaves HEAD alone'
  local before
  before="$(tree_snapshot)"
  git -C "$TREE" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 1 ]
  grep -q '^PULL_FAILED .' <<<"$output"
  [ "$(tree_snapshot)" = "$before" ]
}

# bats test_tags=protected
@test "refuses with a modified tracked file and leaves the tree untouched" {
  make_origin_and_tree
  advance_origin 2.0.4
  echo edited >>"$TREE/pnpm-lock.yaml"
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" pull --tree "$TREE"
  assert_refused uncommitted-changes "$before"
}

# bats test_tags=protected
@test "refuses when diverged from origin, after the fetch, and merges nothing" {
  make_origin_and_tree
  advance_origin 2.0.4
  echo local >"$TREE/local.txt"
  git -C "$TREE" add local.txt
  git -C "$TREE" commit --quiet -m "local only"
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" pull --tree "$TREE"
  assert_refused diverged "$before"
  [ "$(git -C "$TREE" rev-parse FETCH_HEAD)" = "$(git -C "$ORIGIN" rev-parse main)" ]
}
