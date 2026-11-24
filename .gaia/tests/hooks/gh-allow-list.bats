#!/usr/bin/env bats
#
# The root `.claude/settings.json` allow list for `gh`: the forms an unattended
# run needs run without a prompt, and every other form still prompts. Driven
# through the shared matcher in
# `.gaia/tests/helpers/gh-allow-list.sh`, which honors ask and deny rules.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=../helpers/gh-allow-list.sh
  . "$REPO_ROOT/.gaia/tests/helpers/gh-allow-list.sh"
}

@test "the gh forms an unattended run needs are allowed" {
  local command_text
  for command_text in \
    'gh auth status' \
    'gh issue view 12 --json labels' \
    'gh issue edit 12 --add-label in-progress' \
    'gh issue comment 12 --body done' \
    'gh pr create --draft --title "feat: x" --body-file f' \
    'gh pr edit 5 --body-file f' \
    'gh pr comment 5 --body done' \
    'gh pr view 5 --json state' \
    'gh run view 9 --log-failed'; do
    gh_command_is_allowed "$command_text" || { echo "not allowed: $command_text"; return 1; }
  done
}

@test "the gh forms an unattended run must not run unprompted still prompt" {
  local command_text
  for command_text in \
    'gh auth status --show-token' \
    'gh pr merge 5 --squash' \
    'gh pr checkout 5' \
    'gh pr close 5 --delete-branch' \
    'gh pr ready 5' \
    'gh pr comment 5 --delete-last' \
    'gh pr comment --delete-last' \
    'gh issue comment --delete-last' \
    'gh issue comment 12 --delete-last' \
    'gh api repos/o/r' \
    'gh repo delete o/r' \
    'gh release create v1' \
    'gh secret set X' \
    'gh run rerun 9'; do
    if gh_command_is_allowed "$command_text"; then
      echo "allowed without a prompt: $command_text"
      return 1
    fi
  done
}
