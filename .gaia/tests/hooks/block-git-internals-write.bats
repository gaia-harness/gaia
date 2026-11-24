#!/usr/bin/env bats

# Tests for .claude/hooks/block-git-internals-write.sh: an edit-tool write
# anywhere in git's own directory, or to a linked worktree's `.git` file, is
# denied; every other path passes.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOK_ABSOLUTE_PATH=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/block-git-internals-write.sh
}

run_write() {
  local json
  json=$(jq -n --arg tool "$1" --arg file_path "$2" '{tool_name: $tool, tool_input: {file_path: $file_path, content: "x"}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# bats test_tags=protected
@test "a write into .git or to a worktree's .git file is denied, from every edit tool" {
  local tool path
  local -a paths=(
    .git/config
    /repo/.git/config
    /repo/.git/hooks/pre-commit
    /repo/.git/hooks/sub/dir/script
    /repo/.git/worktrees/wt/config.worktree
    /repo/.git/worktrees/wt/commondir
    /repo/.git/worktrees/wt/gitdir
    /repo/.git/info/attributes
    /repo/.claude/worktrees/wt/.git
    /repo/.GIT/Config
  )
  for tool in Write Edit MultiEdit; do
    for path in "${paths[@]}"; do
      echo "case: $tool $path"
      run_write "$tool" "$path"
      assert_denied_by_json
    done
  done
}

@test "a path that only resembles git's directory passes" {
  local path
  local -a paths=(
    /repo/.gitignore
    /repo/.gitattributes
    /repo/.github/workflows/ci.yml
    /repo/.githooks/pre-commit
    /repo/src/git/config
    /repo/docs/.git-notes.md
    ''
  )
  for path in "${paths[@]}"; do
    echo "case: $path"
    run_write Write "$path"
    assert_allowed_by_exit
  done
}
