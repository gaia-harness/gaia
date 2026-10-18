#!/usr/bin/env bats
# update-gaia-pull.sh: the guarded fast-forward of the main checkout's default
# branch. Every case runs against a bare origin and clones in temp dirs, so no
# network is touched. Each observable (the status line, the HEAD move, the
# version pair, the lockfile verdict) has its own test, and each refusal
# asserts the tree is exactly as it was.
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

@test "check on a clean default branch prints PULL_READY main" {
  make_origin_and_tree
  run bash "$SCRIPT" check --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$output" = "PULL_READY main" ]
}

@test "check reads the default branch from a clone whose origin has only master and no origin/HEAD" {
  make_origin_and_tree master
  git -C "$TREE" remote set-head origin -d >/dev/null
  git -C "$TREE" show-ref --verify --quiet refs/remotes/origin/HEAD && return 1
  run bash "$SCRIPT" check --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$output" = "PULL_READY master" ]
}

@test "check never touches the network" {
  make_origin_and_tree
  advance_origin 2.0.4
  local origin_head_before
  origin_head_before="$(git -C "$TREE" rev-parse origin/main)"
  run bash "$SCRIPT" check --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TREE" rev-parse origin/main)" = "$origin_head_before" ]
}

@test "check ignores an untracked file" {
  make_origin_and_tree
  echo scratch >"$TREE/untracked.txt"
  run bash "$SCRIPT" check --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$output" = "PULL_READY main" ]
}

@test "pull fast-forwards HEAD to origin" {
  make_origin_and_tree
  advance_origin 2.0.4
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TREE" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse main)" ]
}

@test "pull prints the old and new version" {
  make_origin_and_tree
  advance_origin 2.0.4
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<<"$output")" = "PULLED 2.0.3 2.0.4" ]
}

@test "pull prints LOCKFILE_CHANGED yes when origin changed pnpm-lock.yaml" {
  make_origin_and_tree
  advance_origin 2.0.4 main lock
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p <<<"$output")" = "LOCKFILE_CHANGED yes" ]
}

@test "pull prints LOCKFILE_CHANGED no when origin left pnpm-lock.yaml alone" {
  make_origin_and_tree
  advance_origin 2.0.4
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p <<<"$output")" = "LOCKFILE_CHANGED no" ]
}

@test "pull counts a lockfile that appears on origin as changed" {
  make_origin_and_tree
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
}

@test "pull works from a clone with only master and no origin/HEAD" {
  make_origin_and_tree master
  git -C "$TREE" remote set-head origin -d >/dev/null
  advance_origin 2.0.4 master
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<<"$output")" = "PULLED 2.0.3 2.0.4" ]
}

@test "pull proceeds with an untracked file present and leaves it alone" {
  make_origin_and_tree
  advance_origin 2.0.4
  echo scratch >"$TREE/untracked.txt"
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(cat "$TREE/untracked.txt")" = "scratch" ]
}

@test "pull when already current prints the same version twice and LOCKFILE_CHANGED no" {
  make_origin_and_tree
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'PULLED 2.0.3 2.0.3\nLOCKFILE_CHANGED no')" ]
}

@test "refuses on a non-default branch and leaves the tree untouched" {
  make_origin_and_tree
  git -C "$TREE" checkout --quiet -b feature
  advance_origin 2.0.4
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" pull --tree "$TREE"
  assert_refused not-default-branch "$before"
}

@test "refuses on a detached HEAD" {
  make_origin_and_tree
  git -C "$TREE" checkout --quiet --detach
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" pull --tree "$TREE"
  assert_refused not-default-branch "$before"
}

@test "refuses with a modified tracked file and leaves the tree untouched" {
  make_origin_and_tree
  advance_origin 2.0.4
  echo edited >>"$TREE/pnpm-lock.yaml"
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" pull --tree "$TREE"
  assert_refused uncommitted-changes "$before"
}

@test "check refuses with a modified tracked file too" {
  make_origin_and_tree
  echo edited >>"$TREE/pnpm-lock.yaml"
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" check --tree "$TREE"
  assert_refused uncommitted-changes "$before"
}

@test "refuses with a staged change and leaves the index untouched" {
  make_origin_and_tree
  advance_origin 2.0.4
  echo staged >"$TREE/new-file.txt"
  git -C "$TREE" add new-file.txt
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" pull --tree "$TREE"
  assert_refused uncommitted-changes "$before"
}

@test "refuses against a linked worktree path" {
  make_origin_and_tree
  git -C "$TREE" worktree add --quiet -b side "$BATS_TEST_TMPDIR/linked" 2>/dev/null
  local before
  before="$(tree_snapshot)"
  run bash "$SCRIPT" pull --tree "$BATS_TEST_TMPDIR/linked"
  assert_refused worktree "$before"
}

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

@test "a local commit origin lacks, with origin otherwise unchanged, is not a divergence" {
  make_origin_and_tree
  echo local >"$TREE/local.txt"
  git -C "$TREE" add local.txt
  git -C "$TREE" commit --quiet -m "local only"
  local head_before
  head_before="$(git -C "$TREE" rev-parse HEAD)"
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TREE" rev-parse HEAD)" = "$head_before" ]
}

@test "a failing fetch prints PULL_FAILED, exits 1 and leaves HEAD alone" {
  make_origin_and_tree
  local before
  before="$(tree_snapshot)"
  git -C "$TREE" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
  run bash "$SCRIPT" pull --tree "$TREE"
  [ "$status" -eq 1 ]
  grep -q '^PULL_FAILED .' <<<"$output"
  [ "$(tree_snapshot)" = "$before" ]
}

@test "usage errors exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" bogus --tree "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" check
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" check --tree
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" check --tree "$BATS_TEST_TMPDIR" --extra
  [ "$status" -eq 2 ]
}

@test "the tracked-changes guard can fail: a scratch copy without it pulls over a modified file" {
  make_origin_and_tree
  advance_origin 2.0.4
  echo edited >>"$TREE/pnpm-lock.yaml"
  local scratch_directory="$BATS_TEST_TMPDIR/scratch-scripts"
  mkdir -p "$scratch_directory"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$scratch_directory/main-root-lib.sh"
  # shellcheck disable=SC2016  # the sed expression is literal text, not shell
  sed 's/^if \[ -n "\$tracked_changes" \]; then$/if false; then/' "$SCRIPT" >"$scratch_directory/update-gaia-pull.sh"
  cmp -s "$SCRIPT" "$scratch_directory/update-gaia-pull.sh" && return 1
  run bash "$scratch_directory/update-gaia-pull.sh" pull --tree "$TREE"
  grep -q '^PULL_REFUSED uncommitted-changes' <<<"$output" && return 1
  [ "$(sed -n 1p <<<"$output")" = "PULLED 2.0.3 2.0.4" ]
}
