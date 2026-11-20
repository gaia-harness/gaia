#!/usr/bin/env bats
# Tests for `.claude/hooks/debt-sentinel-touch.sh`, the PostToolUse Bash hook
# that arms the debt-count staleness sentinel after a debt-count-mutating `gh`
# command (`gh issue create` / `gh pr merge` / `gh issue edit` / `gh issue
# close` / `gh issue reopen`). Arming the sentinel makes the open `tech-debt`
# count recompute on the next statusline tick instead of waiting on the
# refresher's 6h TTL.
#
# Each test runs the hook inside a throwaway git repo (the hook writes the
# sentinel relative to CWD and reads `.claude/hooks/lib/repo-scope.sh` relative to
# CWD; the tmp repo omits that lib, so the repo-scope guard is skipped and a
# matching command proceeds).

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK_ABSOLUTE_PATH=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/debt-sentinel-touch.sh
  command -v jq >/dev/null 2>&1 || skip "jq required"
  SENTINEL_RELATIVE_PATH=".gaia/local/debt/refresh-requested"
}

teardown() {
  # `return 0` because the guard is an AND-list: with no $REPO to remove it
  # would otherwise leave teardown non-zero and fail an innocent test.
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# run_hook <command>: feed a PostToolUse Bash payload carrying <command> to the
# hook, from inside a fresh tmp repo. Leaves $REPO set for assertions.
run_hook() {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO" || return 1
  local input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$1")
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

assert_armed() { [ -f "$REPO/$SENTINEL_RELATIVE_PATH" ]; }
assert_not_armed() { [ ! -f "$REPO/$SENTINEL_RELATIVE_PATH" ]; }

@test "a mutating gh command arms the sentinel: issue create, close, reopen, edit --add-label, edit --remove-label, pr merge, after a separator, in a multi-statement command" {
  local row label command_text
  for row in \
    'issue create|gh issue create --label tech-debt --label severity:minor --body-file /tmp/b.md' \
    'issue close|gh issue close 590' \
    'issue reopen|gh issue reopen 590' \
    'issue edit add-label|gh issue edit 590 --add-label in-progress' \
    'issue edit remove-label|gh issue edit 590 --remove-label in-progress' \
    'pr merge|gh pr merge 42 --auto --squash' \
    'after a shell separator|git status && gh issue close 590' \
    'multi-statement|echo start && gh issue close 590'; do
    label=${row%%|*}; command_text=${row#*|}
    run_hook "$command_text" || { echo "case $label: hook did not exit 0"; return 1; }
    assert_armed || { echo "case $label: sentinel not armed"; return 1; }
    rm -rf "$REPO"
  done
}

@test "a non-Bash tool, gh issue view, gh issue list, gh pr create and close quoted in a body do not arm the sentinel" {
  local row label command_text input
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO" || return 1
  input=$(jq -n '{tool_name:"Edit",tool_input:{file_path:"x"}}')
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ] || { echo "case non-Bash tool: status=$status"; return 1; }
  assert_not_armed || { echo "case non-Bash tool: sentinel armed"; return 1; }
  rm -rf "$REPO"
  for row in \
    'issue view|gh issue view 590' \
    'issue list|gh issue list --label tech-debt --state open' \
    'pr create|gh pr create --title x --body y' \
    'close inside a body string|gh pr create --body "remember to gh issue close 590 later"'; do
    label=${row%%|*}; command_text=${row#*|}
    run_hook "$command_text" || { echo "case $label: hook did not exit 0"; return 1; }
    assert_not_armed || { echo "case $label: sentinel armed"; return 1; }
    rm -rf "$REPO"
  done
}

# ---------- Shared arming decision (data proof, bound, tokenizer) ----------

@test "the hook file is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}

@test "hook-payload.sh missing: exit 0 with empty stdout, the sentinel stays unarmed" {
  local scratch="$BATS_TEST_TMPDIR/scratch-hooks"
  mkdir -p "$scratch/.claude/hooks"
  cp -R "$(dirname "$HOOK_ABSOLUTE_PATH")/lib" "$scratch/.claude/hooks/lib"
  cp "$HOOK_ABSOLUTE_PATH" "$scratch/.claude/hooks/debt-sentinel-touch.sh"
  rm -f "$scratch/.claude/hooks/lib/hook-payload.sh"

  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO" || return 1
  local input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash 'gh issue close 590')
  invoke_hook "$input" "$scratch/.claude/hooks/debt-sentinel-touch.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_not_armed
}
