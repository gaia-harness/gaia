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
  # A gh stub names the home repository for the --repo comparison, so no test
  # reaches the network; it fails while $SCRATCH/no-home exists.
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "repo view" ] || exit 1
[ -e "${GH_STUB_DIRECTORY}/no-home" ] && exit 1
printf '{"nameWithOwner":"Acme/Widgets","url":"https://github.com/Acme/Widgets"}\n'
STUB
  chmod +x "$SCRATCH/bin/gh"
  export GH_STUB_DIRECTORY="$SCRATCH"
  PATH="$SCRATCH/bin:$PATH"
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

# bats test_tags=protected
@test "gh pr create with a SPEC number in the title is blocked and names the match" {
  run_hook 'gh pr create --draft --title "feat: build SPEC-123" --body "plain"'
  assert_blocked
  grep -qF -- '--title line 1: SPEC-123' <<<"$output"
  grep -qF -- '.claude/rules/working-doc-ids.md' <<<"$output"
}

# Rows are `fragment|command`: the fragment is the match the denial names (empty
# when the row asserts only the block); the command is everything after the first
# `|`, so it may be multi-line and carry pipes. The rows span the verbs and flag
# spellings the hook reads: short and equals forms of title and body, a heredoc
# body in a command substitution, body files, a list operator ahead of the
# command, and a --repo naming the home repository (after the subcommand or ahead
# of it).
@test "a machine-local reference in gh text is blocked" {
  local row fragment command_text
  printf '## Summary\n\nImplements SPEC-321.\n' >"$SCRATCH/body.md"
  local rows=(
    '--body line 1: .gaia/local/runs/feat/12-x/STATE.md|gh pr edit 2898 --body "Evidence in .gaia/local/runs/feat/12-x/STATE.md"'
    '.notebook/research/2026-10-07-review/README.md|gh issue create --title "t" --body "see .notebook/research/2026-10-07-review/README.md"'
    '|gh issue edit 12 --title "FLOW-001 fails"'
    '|gh pr edit 12 --body "branch feat/spec-123-x"'
    '|gh issue create -t "SPEC-123" -b "plain"'
    '|gh issue create -t "plain" -b "SPEC-123"'
    '|gh pr create --draft --title=SPEC-123 --body=plain'
    '|gh pr create --draft --title=plain --body=SPEC-123'
    $'--body line 3: SPEC-042|gh pr create --draft --title "fix: y" --body "$(cat <<\'EOF\'\n## Summary\nSee SPEC-042 here\nEOF\n)"'
    "--body-file line 3: SPEC-321|gh pr create --draft --title \"fix: z\" --body-file $SCRATCH/body.md"
    "|gh issue edit 3 -F $SCRATCH/body.md"
    "|gh issue create --title t --body-file=$SCRATCH/body.md"
    '|git push -u origin x && gh pr create --draft --title "fix: x" --body "SPEC-123"'
    '|gh pr create --repo acme/widgets --title "SPEC-123" --body "x"'
    '|gh issue edit 7 -R github.com/ACME/widgets --body "see .gaia/local/runs/feat/12-x/STATE.md"'
    '|gh -R Acme/Widgets pr create --title "SPEC-123" --body "x"'
    '|gh --repo=acme/widgets issue create --title "SPEC-123" --body "x"'
    '|gh pr -R acme/widgets create --title "SPEC-123" --body "x"'
    '|gh -R other/repo issue --repo acme/widgets create --title "SPEC-123" --body "x"'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    fragment=${row%%|*}
    command_text=${row#*|}
    run_hook "$command_text"
    assert_blocked
    if [ -n "$fragment" ]; then
      grep -qF -- "$fragment" <<<"$output"
    fi
  done

  echo "case: a relative body file resolves against the payload cwd"
  mkdir -p "$SCRATCH/work"
  printf 'SPEC-321\n' >"$SCRATCH/work/body.md"
  run_hook 'gh pr edit 12 --body-file body.md' "$SCRATCH/work"
  assert_blocked
}

# Each row sits one spelling away from a deny: a placeholder, a bare number, a
# verb the hook does not read, a body it cannot read (stdin), another
# repository, or a clean body.
@test "clean or unread gh text is allowed" {
  local command_text
  printf '## Summary\n\nCloses #12\n' >"$SCRATCH/clean-body.md"
  mkdir -p "$SCRATCH/work"
  printf 'SPEC-321\n' >"$SCRATCH/work/body.md"
  local rows=(
    'gh pr create --draft --title "feat: build the thing" --body "Closes #2895"'
    'gh issue edit 12 --title "UAT-001 fails"'
    'gh pr view 12 --json body --jq ".body | test(\"SPEC-123\")"'
    'gh pr comment 12 --body "SPEC-123"'
    'gh pr edit 12 --body "State lives in .gaia/local/runs/<branch>/STATE.md; Closes #2895; SPEC-NNN"'
    'gh pr edit 12 --body "revision plan-2"'
    $'gh pr create --draft --title "fix: y" --body "$(cat <<\'EOF\'\n## Summary\nCloses #12\nEOF\n)"'
    "gh pr create --draft --title \"fix: z\" --body-file $SCRATCH/clean-body.md"
    'gh pr edit 12 --body-file -'
    'gh pr create --repo other/repo --title "SPEC-123" --body "x"'
    'gh -R other/repo pr create --title "SPEC-123" --body "x"'
    'gh -R acme/widgets pr create --title "feat: clean" --body "x"'
    'gh pr edit 12 --body-file body.md'
  )
  for command_text in "${rows[@]}"; do
    echo "case: $command_text"
    run_hook "$command_text"
    assert_allowed
  done

  echo "case: a --repo is not read when gh cannot name the home repository"
  : >"$SCRATCH/no-home"
  run_hook 'gh -R acme/widgets pr create --title "SPEC-123" --body "x"'
  assert_allowed
  rm -f "$SCRATCH/no-home"

  echo "case: a non-Bash tool call"
  local payload
  payload=$(jq -nc '{tool_name: "Write", tool_input: {file_path: "/tmp/x", content: "SPEC-123"}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$HOOK"
  assert_allowed
}

# --- registration ------------------------------------------------------------

@test "the hook is registered on PreToolUse Bash in both settings files" {
  local settings
  for settings in "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/apps/web/.claude/settings.json"; do
    jq -e '[.hooks.PreToolUse[] | select(.matcher | test("(^|\\|)Bash(\\||$)")) | .hooks[].command]
      | any(endswith("/.claude/hooks/block-machine-local-ref-gh-text.sh\""))' "$settings" >/dev/null
  done
}

@test "an allowed gh pr edit form is still blocked when its body cites a machine-local path" {
  # shellcheck source=../helpers/gh-allow-list.sh
  . "$REPO_ROOT/.gaia/tests/helpers/gh-allow-list.sh"
  gh_command_is_allowed 'gh pr edit 2898 --body "Evidence in .gaia/local/runs/feat/12-x/STATE.md"'
  run_hook 'gh pr edit 2898 --body "Evidence in .gaia/local/runs/feat/12-x/STATE.md"'
  assert_blocked
}
