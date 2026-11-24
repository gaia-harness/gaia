#!/usr/bin/env bats

# Tests for the sub-agent rule of .claude/hooks/block-main-destructive-git.sh:
# a sub-agent's git that changes state is denied, whatever
# classify-git-command.sh would approve. The hook header states the outcome for
# each payload shape; lib/subagent-git-policy.sh holds the subcommands and the
# exempt agents, and the denied, stash-read and exempt lists here are read from it.
#
# Both hooks judge "this repository" from their own on-disk location, so each
# test copies them and their libraries into a fresh fixture repository on a
# feature branch, where every other rule of the guard allows a commit or push.
# Commands reach the hooks as payload text and never run.

# shellcheck disable=SC2016  # jq programs are single-quoted so their `$` reaches jq

setup() {
  SOURCE_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  cp "$SOURCE_ROOT/.claude/hooks/block-main-destructive-git.sh" "$REPO/.claude/hooks/"
  cp "$SOURCE_ROOT/.claude/hooks/classify-git-command.sh" "$REPO/.claude/hooks/"
  cp "$SOURCE_ROOT"/.claude/hooks/lib/*.sh "$REPO/.claude/hooks/lib/"
  cp "$SOURCE_ROOT/.gaia/scripts/main-root-lib.sh" "$REPO/.gaia/scripts/"
  GUARD="$REPO/.claude/hooks/block-main-destructive-git.sh"
  CLASSIFIER="$REPO/.claude/hooks/classify-git-command.sh"
  POLICY="$REPO/.claude/hooks/lib/subagent-git-policy.sh"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" commit --quiet --allow-empty -m init
  git -C "$REPO" checkout --quiet -b feature
  FOREIGN="$BATS_TEST_TMPDIR/foreign"
  # Off main, so the guard's main-branch rules leave its commits alone.
  git init --quiet --initial-branch=feature "$FOREIGN"
  # The probed shape of a fork's payload: agent_id and agent_type "fork" at
  # the top level, beside the common fields (wiki/concepts/Claude Hooks.md).
  FORK='{"agent_id": "aaa7f669884a8e56f", "agent_type": "fork"}'
  EXECUTOR='{"agent_id": "a65f5edc2f422ae00", "agent_type": "general-purpose"}'
  MAIN_THREAD='{}'
}

# payload <command> <agent fields JSON>: a Bash PreToolUse payload from the
# fixture repository carrying the given top-level agent fields.
payload() {
  jq -cn --arg command "$1" --arg directory "$REPO" --argjson agent "$2" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", cwd: $directory, tool_input: {command: $command}} + $agent'
}

# run_raw <hook> <raw payload>: the hook on that payload, from the fixture repository.
run_raw() {
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$2" "$1"
}

guard() { run_raw "$GUARD" "$(payload "$1" "$2")"; }

assert_subagent_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
  grep -qF -- 'Sub-agents never run git that changes state' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# policy_list <array name>: print each member of one policy list, one per line.
policy_list() {
  bash -c '. "$1"; eval "printf \"%s\\n\" \"\${$2[@]}\""' _ "$POLICY" "$1"
}

# bats test_tags=protected
@test "an executor's git commit is denied with a message citing the doctrine and saying the main thread commits" {
  guard 'git commit -m change' "$EXECUTOR"
  assert_subagent_denied
  grep -qF -- '.claude/doctrine/execution.md' <<<"$output"
  grep -qF -- 'The main thread commits' <<<"$output"
}

@test "a sub-agent's commit and push the classifier allows are still denied" {
  local command
  for command in 'git commit -m change' 'git push -u origin feature'; do
    echo "case: $command"
    run_raw "$CLASSIFIER" "$(payload "$command" "$EXECUTOR")"
    [ "$status" -eq 0 ]
    grep -qF -- '"permissionDecision": "allow"' <<<"$output"
    guard "$command" "$EXECUTOR"
    assert_subagent_denied
  done
}

@test "run in .claude/settings.json registration order, both hooks leave an executor's and a fork's commit denied" {
  local hook agent decision verdicts
  local -a order=()
  while IFS= read -r hook; do order+=("$hook"); done < <(
    jq -r '.hooks.PreToolUse[] | select(.matcher | split("|") | index("Bash")) | .hooks[].command
      | capture("/\\.claude/hooks/(?<name>[^/\"]+\\.sh)").name' "$SOURCE_ROOT/.claude/settings.json" |
      grep -xE 'block-main-destructive-git\.sh|classify-git-command\.sh')
  [ "${#order[@]}" -eq 2 ]
  for agent in "$EXECUTOR" "$FORK"; do
    verdicts=""
    for hook in "${order[@]}"; do
      run_raw "$REPO/.claude/hooks/$hook" "$(payload 'git commit -m change' "$agent")"
      [ "$status" -eq 0 ]
      decision=none
      [ -z "$output" ] || decision=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")
      verdicts="$verdicts $hook=$decision"
    done
    echo "case: $agent |$verdicts"
    # A PreToolUse deny from any hook beats another hook's allow, so the call
    # is denied exactly when one of them denies.
    grep -qF -- ' classify-git-command.sh=allow' <<<"$verdicts"
    grep -qF -- ' block-main-destructive-git.sh=deny' <<<"$verdicts"
  done
}

@test "every listed subcommand is denied to a sub-agent and a fork, and every stash write form with it" {
  local subcommand agent count=0
  while IFS= read -r subcommand; do
    count=$((count + 1))
    for agent in "$EXECUTOR" "$FORK"; do
      echo "case: git $subcommand | $agent"
      guard "git $subcommand" "$agent"
      assert_subagent_denied
    done
  done < <(policy_list GAIA_SUBAGENT_DENIED_GIT_SUBCOMMANDS)
  [ "$count" -gt 0 ]
  for subcommand in 'stash push -m x' 'stash pop' 'stash drop' 'stash apply' 'stash clear'; do
    echo "case: git $subcommand"
    guard "git $subcommand" "$EXECUTOR"
    assert_subagent_denied
  done
}

@test "read-only git in a sub-agent is allowed: status, diff, log and every stash read verb" {
  local command count=0
  for command in 'git status' 'git diff' 'git log --oneline -1' 'git rev-parse HEAD' 'git stash list'; do
    echo "case: $command"
    guard "$command" "$EXECUTOR"
    assert_allowed
  done
  while IFS= read -r command; do
    count=$((count + 1))
    echo "case: git stash $command"
    guard "git stash $command" "$EXECUTOR"
    assert_allowed
  done < <(policy_list GAIA_SUBAGENT_GIT_STASH_READ_VERBS)
  [ "$count" -gt 0 ]
}

@test "the main thread and every exempt agent may commit and push" {
  local agent_type count=0
  guard 'git commit -m change' "$MAIN_THREAD"
  assert_allowed
  while IFS= read -r agent_type; do
    count=$((count + 1))
    echo "case: $agent_type"
    guard 'git commit -m change && git push -u origin feature' \
      "$(jq -cn --arg type "$agent_type" '{agent_id: "a1b2c3", agent_type: $type}')"
    assert_allowed
  done < <(policy_list GAIA_SUBAGENT_GIT_EXEMPT_AGENTS)
  [ "$count" -gt 0 ]
}

@test "a sub-agent's state-changing git on a foreign repository is allowed, and the home segment beside it is not" {
  guard "git -C $FOREIGN commit -m change" "$EXECUTOR"
  assert_allowed
  guard "cd $FOREIGN && git commit -m change" "$EXECUTOR"
  assert_allowed
  guard "git status && git -C $FOREIGN commit -m change" "$EXECUTOR"
  assert_allowed
  guard "git -C $FOREIGN commit -m change && git commit -m change" "$EXECUTOR"
  assert_subagent_denied
}

@test "a garbled identity is a restricted sub-agent; a lookalike in the command or a payload that is not JSON is not" {
  local agent
  for agent in '{"agent_id": 5, "agent_type": "audit-loop-unit"}' \
      '{"agent_id": "../x", "agent_type": "general-purpose"}' \
      '{"agent_id": "a1b2c3"}' \
      '{"agent_id": "a1b2c3", "agent_type": 7}' \
      '{"agent_id": "a1b2c3", "agent_type": "audit-loop-unit-x"}'; do
    echo "case: $agent"
    guard 'git commit -m change' "$agent"
    assert_subagent_denied
  done
  guard 'git commit -m "\"agent_id\": \"a1\", \"agent_type\": \"fork\""' "$MAIN_THREAD"
  assert_allowed
  guard 'git commit -m "\"agent_type\":\"audit-loop-unit\""' "$EXECUTOR"
  assert_subagent_denied
  run_raw "$GUARD" '{"tool_name": "Bash", "agent_id": "a1", "tool_input": {"command": "git commit -m x"'
  assert_allowed
}

@test "a missing policy or identity library blocks the call loudly" {
  local library
  for library in subagent-git-policy payload-agent; do
    echo "case: $library"
    mv "$REPO/.claude/hooks/lib/$library.sh" "$BATS_TEST_TMPDIR/$library.sh"
    guard 'git status' "$MAIN_THREAD"
    [ "$status" -eq 2 ]
    grep -qF -- "cannot load lib/$library.sh" <<<"$output"
    mv "$BATS_TEST_TMPDIR/$library.sh" "$REPO/.claude/hooks/lib/$library.sh"
  done
}
