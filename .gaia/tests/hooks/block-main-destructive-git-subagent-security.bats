#!/usr/bin/env bats

# Access rule of .claude/hooks/block-main-destructive-git.sh: a non-exempt
# sub-agent's denied git subcommand in this repository is allowed only from the
# linked worktree named agent-<its own agent id>, and only in a command that
# cannot reach another tree. Commands reach the hook as payload text and never
# run, so a refusal is the deny decision itself.

# shellcheck disable=SC2016  # jq programs are single-quoted so their `$` reaches jq

setup() {
  SOURCE_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  cp "$SOURCE_ROOT/.claude/hooks/block-main-destructive-git.sh" "$REPO/.claude/hooks/"
  cp "$SOURCE_ROOT/.claude/hooks/classify-git-command.sh" "$REPO/.claude/hooks/"
  cp "$SOURCE_ROOT"/.claude/hooks/lib/*.sh "$REPO/.claude/hooks/lib/"
  cp "$SOURCE_ROOT/.gaia/scripts/main-root-lib.sh" "$REPO/.gaia/scripts/"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" commit --quiet --allow-empty -m init
  git -C "$REPO" checkout --quiet -b feature
  AGENT_ID="a65f5edc2f422ae00"
  OTHER_AGENT_ID="b0000000000000000"
  AGENT=$(jq -cn --arg id "$AGENT_ID" '{agent_id: $id, agent_type: "general-purpose"}')
}

# run_in_tree <directory> <command>: the guard copied into <directory> (a tree
# of the fixture repository), run there as the sub-agent.
run_in_tree() {
  mkdir -p "$1/.claude/hooks" "$1/.gaia/scripts"
  [ "$1" = "$REPO" ] || cp -R "$REPO/.claude/hooks/." "$1/.claude/hooks/"
  [ "$1" = "$REPO" ] || cp "$REPO/.gaia/scripts/main-root-lib.sh" "$1/.gaia/scripts/"
  run bash -c 'cd "$1" && printf %s "$2" | bash "$1/.claude/hooks/block-main-destructive-git.sh"' _ "$1" \
    "$(jq -cn --arg c "$2" --arg d "$1" --argjson a "$AGENT" \
      '{hook_event_name: "PreToolUse", tool_name: "Bash", cwd: $d, tool_input: {command: $c}} + $a')"
}

# run_in_worktree <worktree name> <command>: a linked worktree with that name.
run_in_worktree() {
  git -C "$REPO" worktree add --quiet -b "branch-$1" "$BATS_TEST_TMPDIR/$1"
  run_in_tree "$BATS_TEST_TMPDIR/$1" "$2"
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
  grep -qF -- 'Sub-agents never run git that changes state' <<<"$output"
}

@test "a sub-agent may commit and push in the linked worktree named for its own agent id" {
  local own="$BATS_TEST_TMPDIR/agent-$AGENT_ID" command
  run_in_worktree "agent-$AGENT_ID" 'git commit -m change'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  for command in \
    'git add -A && git commit -F message.txt && git push -u origin feature' \
    "git -C $own commit -m change" \
    'git -C . commit -m change'; do
    echo "case: $command"
    run_in_tree "$own" "$command"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

# bats test_tags=protected
@test "from its own worktree, a sub-agent is denied any command that could reach another tree" {
  local own="$BATS_TEST_TMPDIR/agent-$AGENT_ID" command
  git -C "$REPO" worktree add --quiet -b "branch-agent-$AGENT_ID" "$own"
  # A directory literally named `$X` in the own tree: the shell would expand
  # the quoted word to wherever X points, so it must not read as the own tree.
  mkdir -p "$own/\$X"
  for command in \
    "git -C $REPO commit -m change" \
    "git -C $REPO reset --hard HEAD~1" \
    'git -C "$X" commit -m change' \
    "cd $REPO && git checkout -- file" \
    "pushd $REPO && git commit -m change" \
    "sh -c 'cd $REPO && git reset --hard'" \
    "GIT_DIR=$REPO/.git git commit -m change" \
    "git --git-dir=$REPO/.git commit -m change" \
    "git --work-tree $REPO commit -m change" \
    "git -c core.worktree=$REPO commit -m change" \
    "git -C $own -C $REPO commit -m change" \
    "git -C $own -c core.worktree=$REPO commit -m change" \
    "git -C $own --git-dir=$REPO/.git commit -m change" \
    'git stash pop' \
    'git stash drop' \
    'git stash clear' \
    'git stash push -m work' \
    'git stash' \
    "git -C $own stash pop" \
    'git checkout --ignore-other-worktrees -B branch-main HEAD' \
    'git checkout --ignore-o -B branch-main HEAD' \
    'git switch --ignore-other -C branch-main' \
    'git checkout "--ignore-other-worktrees" -B branch-main HEAD' \
    "git switch '--ignore-o' -C branch-main" \
    "git commit -m \"\$(cd $REPO && git reset --hard)\"" \
    "git commit -m \"\`cd $REPO; git reset --hard\`\""; do
    echo "case: $command"
    run_in_tree "$own" "$command"
    assert_denied
  done
}

# bats test_tags=protected
@test "a sub-agent is denied a commit in every tree except the worktree named for its own agent id" {
  local name
  # Another agent's worktree, then names that merely contain or prefix the id.
  for name in "agent-$OTHER_AGENT_ID" "agent-$AGENT_ID-other" "xagent-$AGENT_ID" "agent-${AGENT_ID}x" "$AGENT_ID"; do
    echo "case: worktree $name"
    run_in_worktree "$name" 'git commit -m change'
    assert_denied
  done
  echo "case: main checkout"
  run_in_tree "$REPO" 'git commit -m change'
  assert_denied
  # A main checkout (a `.git` directory, not a linked worktree) that happens to
  # carry the agent's name.
  echo "case: main checkout named agent-$AGENT_ID"
  local named="$BATS_TEST_TMPDIR/agent-$AGENT_ID"
  git clone --quiet "$REPO" "$named"
  git -C "$named" checkout --quiet -b feature-copy
  run_in_tree "$named" 'git commit -m change'
  assert_denied
}

# bats test_tags=protected
@test "from its own worktree, a sub-agent is denied --ignore-other-worktrees in every abbreviated or quoted spelling and the parent's branch does not move" {
  local own="$BATS_TEST_TMPDIR/agent-$AGENT_ID" command before after
  git -C "$REPO" worktree add --quiet -b "branch-agent-$AGENT_ID" "$own"
  before=$(git -C "$REPO" rev-parse feature)
  for command in \
    'git checkout --ignore-other-worktrees -B feature HEAD' \
    'git checkout --ignore-other -B feature HEAD' \
    'git checkout --ignore-o -B feature HEAD' \
    'git checkout "--ignore-other-worktrees" -B feature HEAD' \
    "git checkout '--ignore-o' -B feature HEAD" \
    "git checkout --ignore-'other-worktrees' -B feature HEAD" \
    'git switch --ignore-other-worktrees -C feature' \
    'git switch --ignore-other -C feature' \
    'git switch --ignore-o -C feature' \
    'git switch "--ignore-other-worktrees" -C feature' \
    "git switch '--ignore-o' -C feature"; do
    echo "case: $command"
    run_in_tree "$own" "$command"
    assert_denied
  done
  after=$(git -C "$REPO" rev-parse feature)
  [ "$before" = "$after" ]
}
