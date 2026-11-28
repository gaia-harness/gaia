#!/usr/bin/env bats

# The stash rule of .claude/hooks/block-main-destructive-git.sh. Every linked
# worktree shares one stash stack, so a pop, apply, drop, branch or clear run in
# one tree can take an entry another tree made. The rule lets those verbs act only
# on entries whose subject names the acting checkout's branch; the rule's own
# header in lib/main-git-guard-stash.sh owns the full contract.
#
# Fixture: a main checkout on main and two linked worktrees, wt-a and wt-b,
# each on a branch of the same name. Each test pushes the entries it needs and
# drives the hook from the tree the payload's cwd names.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOK_ABSOLUTE_PATH="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/block-main-destructive-git.sh"

  REPO=$(mktemp -d -t stash-guard-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo base >"$REPO/f.txt"
  git -C "$REPO" add f.txt
  git -C "$REPO" commit --quiet -m base
  TREE_A="$BATS_TEST_TMPDIR/wt-a"
  TREE_B="$BATS_TEST_TMPDIR/wt-b"
  git -C "$REPO" worktree add --quiet -b wt-a "$TREE_A"
  git -C "$REPO" worktree add --quiet -b wt-b "$TREE_B"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  return 0
}

# stash_in <tree> <message>: push one entry made in <tree>.
stash_in() {
  echo "$2" >>"$1/f.txt"
  git -C "$1" stash push --quiet -m "$2"
}

run_hook_from() {
  local json
  json=$(jq -n --arg command "$1" --arg directory "$2" '{tool_name: "Bash", cwd: $directory, tool_input: {command: $command}}')
  invoke_hook_in "$2" "$json" "$HOOK_ABSOLUTE_PATH"
}

# bats test_tags=protected
@test "each stash write verb on another tree's entry is denied" {
  stash_in "$TREE_A" "A wip"
  local entry_hash
  entry_hash=$(git -C "$TREE_A" rev-parse 'stash@{0}')
  local command
  for command in 'git stash pop' 'git stash apply' 'git stash drop' 'git stash clear' \
    'git stash pop stash@{0}' 'git stash apply --index stash@{0}' 'git stash drop -q 0' \
    "git stash apply $entry_hash" 'git stash branch carried' "git -C $TREE_B stash pop"; do
    run_hook_from "$command" "$TREE_B"
    assert_denied_by_json || { echo "not denied: $command"; return 1; }
  done
  git -C "$TREE_A" stash list | grep -qF 'On wt-a: A wip'
}

@test "the denial names the entry's branch and the person's path" {
  stash_in "$TREE_A" "A wip"
  run_hook_from 'git stash pop' "$TREE_B"
  assert_denied_by_json
  grep -qF "made on 'wt-a'" <<<"$output"
  grep -qF "'wt-b'" <<<"$output"
  grep -qF '! prefix' <<<"$output"
}

@test "each stash write verb on the tree's own entry is allowed" {
  stash_in "$TREE_A" "A wip"
  local entry_hash
  entry_hash=$(git -C "$TREE_A" rev-parse 'stash@{0}')
  local command
  for command in 'git stash pop' 'git stash apply' 'git stash drop' 'git stash clear' \
    'git stash pop stash@{0}' 'git stash apply --index 0' "git stash apply $entry_hash" \
    'git stash branch carried'; do
    run_hook_from "$command" "$TREE_A"
    assert_allowed_by_json || { echo "denied: $command"; return 1; }
  done
}

@test "a bare pop reads stash@{0}, and an explicit index picks the tree's own entry under a peer's" {
  stash_in "$TREE_A" "A wip"
  stash_in "$TREE_B" "B wip"
  run_hook_from 'git stash pop' "$TREE_A"
  assert_denied_by_json
  run_hook_from 'git stash pop stash@{1}' "$TREE_A"
  assert_allowed_by_json
}

@test "a stash write that follows a stack-shifting stash in one command is denied while a peer's entry is on the stack" {
  stash_in "$TREE_B" "B wip"
  stash_in "$TREE_A" "A wip"
  echo more >>"$TREE_A/f.txt"
  local command
  for command in 'git stash drop && git stash drop' 'git stash drop stash@{0}; git stash drop stash@{0}' \
    'git stash push -m x ; git stash drop stash@{1}' 'git stash pop && git stash pop stash@{0}'; do
    run_hook_from "$command" "$TREE_A"
    assert_denied_by_json || { echo "not denied: $command"; return 1; }
  done
  # one segment, a hash-named second segment, and a stack with no peer entry stay allowed
  run_hook_from 'git stash drop' "$TREE_A"
  assert_allowed_by_json
  local own_hash
  own_hash=$(git -C "$TREE_A" rev-parse 'stash@{0}')
  run_hook_from "git stash drop && git stash drop $own_hash" "$TREE_A"
  assert_allowed_by_json
  git -C "$TREE_B" stash drop --quiet 'stash@{1}'
  run_hook_from 'git stash drop && git stash drop' "$TREE_A"
  assert_allowed_by_json
}

@test "clear is denied while any entry belongs to another branch" {
  stash_in "$TREE_A" "A wip"
  stash_in "$TREE_B" "B wip"
  run_hook_from 'git stash clear' "$TREE_A"
  assert_denied_by_json
}

@test "reading and creating a stash are allowed on a shared stack" {
  stash_in "$TREE_A" "A wip"
  local command
  for command in 'git stash list' 'git stash show' 'git stash show -p stash@{0}' \
    'git stash' 'git stash push -m mine' 'git stash -u' 'git stash create'; do
    run_hook_from "$command" "$TREE_B"
    assert_allowed_by_json || { echo "denied: $command"; return 1; }
  done
}

@test "an empty stack has nothing to take, so a write verb is allowed" {
  run_hook_from 'git stash pop' "$TREE_B"
  assert_allowed_by_json
}

@test "a detached HEAD and an entry with no branch in its subject fail closed" {
  stash_in "$TREE_A" "A wip"
  git -C "$TREE_B" checkout --quiet --detach
  run_hook_from 'git stash pop' "$TREE_B"
  assert_denied_by_json
  git -C "$TREE_B" checkout --quiet wt-b
  echo stray >>"$TREE_B/f.txt"
  local created_hash stray_hash
  created_hash=$(git -C "$TREE_B" stash create)
  git -C "$TREE_B" checkout --quiet -- f.txt
  stray_hash=$(git -C "$TREE_B" commit-tree -p HEAD -p "$created_hash^2" -m 'autostash' "$created_hash^{tree}")
  git -C "$TREE_B" stash store -m 'autostash' "$stray_hash"
  run_hook_from 'git stash drop' "$TREE_B"
  assert_denied_by_json
}

# bats test_tags=protected
@test "an entry made under a worktree- spelling is this tree's own once the branch is renamed" {
  local tree_c="$BATS_TEST_TMPDIR/wt-c"
  git -C "$REPO" worktree add --quiet -b 'worktree-fix+12-thing' "$tree_c"
  stash_in "$tree_c" "C wip"
  run_hook_from 'git stash pop' "$TREE_B"
  assert_denied_by_json
  git -C "$tree_c" branch -m 'worktree-fix+12-thing' fix/12-thing
  run_hook_from 'git stash pop' "$tree_c"
  assert_allowed_by_json
  run_hook_from 'git stash pop' "$TREE_B"
  assert_denied_by_json
}
