#!/usr/bin/env bats

# Tests for .claude/hooks/block-machine-local-ref-gh-text.sh, the PreToolUse
# guard that refuses a `gh pr create|edit` or `gh issue create|edit` whose
# title or body cites a machine-local reference. Exit 2 = block, 0 = allow.
#
# Every deny is paired with an allow one spelling away (a placeholder, a bare
# number, a verb the hook does not read), so a hook that blocks everything or
# nothing fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup_file() {
  command -v jq >/dev/null 2>&1 || {
    printf 'jq is required\n' >&3
    return 1
  }
}

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK="$REPO_ROOT/.claude/hooks/block-machine-local-ref-gh-text.sh"
  SCRATCH=$(mktemp -d)
}

teardown() {
  if [ -n "${SCRATCH:-}" ]; then
    rm -rf "$SCRATCH"
  fi
  return 0
}

# run_hook <command> [<cwd>]
run_hook() {
  local payload
  payload=$(jq -nc --arg command "$1" --arg cwd "${2:-$SCRATCH}" \
    '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $command}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$HOOK"
}

assert_blocked() {
  [ "$status" -eq 2 ]
  grep -qF -- 'BLOCKED' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- each verb the hook reads ------------------------------------------------

@test "gh pr create with a SPEC number in the title is blocked and names the match" {
  run_hook 'gh pr create --draft --title "feat: build SPEC-123" --body "plain"'
  assert_blocked
  grep -qF -- '--title line 1: SPEC-123' <<<"$output"
  grep -qF -- '.claude/rules/working-doc-ids.md' <<<"$output"
}

@test "gh pr create with a clean title and body is allowed" {
  run_hook 'gh pr create --draft --title "feat: build the thing" --body "Closes #2895"'
  assert_allowed
}

@test "gh pr edit with a run-folder path in the body is blocked" {
  run_hook 'gh pr edit 2898 --body "Evidence in .gaia/local/runs/feat/12-x/STATE.md"'
  assert_blocked
  grep -qF -- '--body line 1: .gaia/local/runs/feat/12-x/STATE.md' <<<"$output"
}

@test "gh issue create with a research folder in the body is blocked" {
  run_hook 'gh issue create --title "t" --body "see .notebook/research/2026-10-07-review/README.md"'
  assert_blocked
  grep -qF -- '.notebook/research/2026-10-07-review/README.md' <<<"$output"
}

@test "gh issue edit with a UAT number in the title is blocked" {
  run_hook 'gh issue edit 12 --title "UAT-001 fails"'
  assert_blocked
}

@test "a gh pr view carrying a SPEC number is not read" {
  run_hook 'gh pr view 12 --json body --jq ".body | test(\"SPEC-123\")"'
  assert_allowed
}

@test "gh pr comment is not read" {
  run_hook 'gh pr comment 12 --body "SPEC-123"'
  assert_allowed
}

# --- what passes the detector ------------------------------------------------

@test "a placeholder run-folder path and a bare issue number are allowed" {
  run_hook 'gh pr edit 12 --body "State lives in .gaia/local/runs/<branch>/STATE.md; Closes #2895; SPEC-NNN"'
  assert_allowed
}

@test "a lowercase three-digit spec id is blocked, a one-digit plan revision is allowed" {
  run_hook 'gh pr edit 12 --body "branch feat/spec-123-x"'
  assert_blocked
  run_hook 'gh pr edit 12 --body "revision plan-2"'
  assert_allowed
}

# --- flag spellings ----------------------------------------------------------

@test "the short and equals spellings of title and body are read" {
  run_hook 'gh issue create -t "SPEC-123" -b "plain"'
  assert_blocked
  run_hook 'gh issue create -t "plain" -b "SPEC-123"'
  assert_blocked
  run_hook 'gh pr create --draft --title=SPEC-123 --body=plain'
  assert_blocked
  run_hook 'gh pr create --draft --title=plain --body=SPEC-123'
  assert_blocked
}

@test "a heredoc body in a command substitution is scanned" {
  run_hook $'gh pr create --draft --title "fix: y" --body "$(cat <<\'EOF\'\n## Summary\nSee SPEC-042 here\nEOF\n)"'
  assert_blocked
  grep -qF -- '--body line 3: SPEC-042' <<<"$output"
}

@test "a clean heredoc body in a command substitution is allowed" {
  run_hook $'gh pr create --draft --title "fix: y" --body "$(cat <<\'EOF\'\n## Summary\nCloses #12\nEOF\n)"'
  assert_allowed
}

# --- body files --------------------------------------------------------------

@test "a body file citing a SPEC number is blocked, by --body-file, -F and --body-file=" {
  printf '## Summary\n\nImplements SPEC-321.\n' >"$SCRATCH/body.md"
  run_hook "gh pr create --draft --title \"fix: z\" --body-file $SCRATCH/body.md"
  assert_blocked
  grep -qF -- "--body-file line 3: SPEC-321" <<<"$output"
  run_hook "gh issue edit 3 -F $SCRATCH/body.md"
  assert_blocked
  run_hook "gh issue create --title t --body-file=$SCRATCH/body.md"
  assert_blocked
}

@test "a clean body file is allowed" {
  printf '## Summary\n\nCloses #12\n' >"$SCRATCH/body.md"
  run_hook "gh pr create --draft --title \"fix: z\" --body-file $SCRATCH/body.md"
  assert_allowed
}

@test "a relative body file resolves against the payload cwd" {
  mkdir -p "$SCRATCH/work"
  printf 'SPEC-321\n' >"$SCRATCH/work/body.md"
  run_hook 'gh pr edit 12 --body-file body.md' "$SCRATCH/work"
  assert_blocked
  run_hook 'gh pr edit 12 --body-file body.md' "$SCRATCH"
  assert_allowed
}

@test "a body read from stdin is not read" {
  run_hook 'gh pr edit 12 --body-file -'
  assert_allowed
}

# --- command shape -----------------------------------------------------------

@test "a gh pr create after a list operator is read" {
  run_hook 'git push -u origin x && gh pr create --draft --title "fix: x" --body "SPEC-123"'
  assert_blocked
}

@test "a pull request in another repository is not read" {
  run_hook 'gh pr create --repo other/repo --title "SPEC-123" --body "x"'
  assert_allowed
}

@test "a non-Bash tool call is allowed" {
  local payload
  payload=$(jq -nc '{tool_name: "Write", tool_input: {file_path: "/tmp/x", content: "SPEC-123"}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$HOOK"
  assert_allowed
}

# --- registration ------------------------------------------------------------

@test "the hook is registered on PreToolUse Bash in both settings files" {
  local settings
  for settings in "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/frontend/.claude/settings.json"; do
    jq -e '[.hooks.PreToolUse[] | select(.matcher | test("(^|\\|)Bash(\\||$)")) | .hooks[].command]
      | any(endswith("/.claude/hooks/block-machine-local-ref-gh-text.sh\""))' "$settings" >/dev/null
  done
}
