#!/usr/bin/env bats
#
# Harness-level test of the flow "an implementer mid-build changes a test it
# wrote earlier, commits, and nothing refuses". It derives, from both settings
# files, every PreToolUse hook whose matcher can match Bash (the commit set)
# and every one whose matcher can match Edit, Write or MultiEdit (the edit
# set), runs each hook against a staged or edited test file, and asserts the
# decision equals the same hook's decision on a non-test control.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/commit-allows-test-edits.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

TEST_FILE='apps/web/app/utils/tests/sample.test.ts'
SOURCE_FILE='apps/web/app/utils/sample.ts'
NEW_TEST_FILE='apps/web/app/utils/tests/added.test.ts'

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SETTINGS_FILES="$REPO_ROOT/.claude/settings.json $REPO_ROOT/apps/web/.claude/settings.json"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  unset GIT_DIR GIT_WORK_TREE

  STUB_DIRECTORY="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIRECTORY"
  printf '#!/bin/sh\nexit 1\n' >"$STUB_DIRECTORY/gh"
  chmod +x "$STUB_DIRECTORY/gh"

  CONTROL_REPO="$BATS_TEST_TMPDIR/control"
  TEST_REPO="$BATS_TEST_TMPDIR/variant"
  build_fixture "$CONTROL_REPO"
  build_fixture "$TEST_REPO"
  # (a) control: an edit to the non-test source file only.
  printf 'export const sample = 2;\n' >"$CONTROL_REPO/$SOURCE_FILE"
  git -C "$CONTROL_REPO" add "$SOURCE_FILE"
  # (b) variant: an edit to the committed test plus a new passing test with no
  # recorded failing run.
  printf 'import {expect, test} from "vitest";\ntest("sample", () => {\n  expect(2).toBe(2);\n});\n' >"$TEST_REPO/$TEST_FILE"
  printf 'import {expect, test} from "vitest";\ntest("added", () => {\n  expect(3).toBe(3);\n});\n' >"$TEST_REPO/$NEW_TEST_FILE"
  git -C "$TEST_REPO" add "$TEST_FILE" "$NEW_TEST_FILE"
}

build_fixture() {
  local repo="$1"
  mkdir -p "$repo/$(dirname "$TEST_FILE")"
  git -C "$repo" init -q -b feature/sample
  git -C "$repo" config commit.gpgsign false
  printf 'export const sample = 1;\n' >"$repo/$SOURCE_FILE"
  printf 'import {expect, test} from "vitest";\ntest("sample", () => {\n  expect(1).toBe(1);\n});\n' >"$repo/$TEST_FILE"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
}

# registered_commands SETTINGS TOOL: one command per registration whose matcher
# can match TOOL (a matcher alternative equal to it, or an empty matcher).
registered_commands() {
  jq -r --arg tool "$2" '
    .hooks.PreToolUse[]
    | select((.matcher // "") as $matcher
        | $matcher == "" or $matcher == "*" or (($matcher | split("|")) | index($tool) != null))
    | .hooks[] | select(.type == "command") | .command' "$1"
}

# registration_count SETTINGS TOOL: the same count by an independent query
# (a regex over the matcher string instead of a split).
registration_count() {
  jq --arg tool "$2" '
    [.hooks.PreToolUse[]
     | select((.matcher // "") | test("^(\\*)?$") or test("(^|\\|)" + $tool + "(\\||$)"))
     | .hooks[] | select(.type == "command")] | length' "$1"
}

# derive_set TOOLS...: every command registered for any of TOOLS across both
# settings files, one per line, duplicates kept (one line per registration).
derive_set() {
  local settings tool
  for settings in $SETTINGS_FILES; do
    for tool in "$@"; do
      registered_commands "$settings" "$tool"
    done
  done
}

derived_count() {
  local settings tool total=0 count
  for settings in $SETTINGS_FILES; do
    for tool in "$@"; do
      count="$(registration_count "$settings" "$tool")"
      total=$((total + count))
    done
  done
  printf '%s' "$total"
}

# resolve_hook COMMAND: the absolute hook path under the real repo root, or
# nothing (status 1) when the command does not have the rooted registration
# form or does not name an executable file there.
resolve_hook() {
  local relative_path absolute_path
  relative_path="$(printf '%s' "$1" | sed -n 's|^.*[")]\(/\.claude/hooks/[^"]*\.sh\)"$|\1|p')"
  [ -n "$relative_path" ] || return 1
  absolute_path="$REPO_ROOT$relative_path"
  [ -f "$absolute_path" ] && [ -x "$absolute_path" ] || return 1
  case "$absolute_path" in "$REPO_ROOT"/*) ;; *) return 1 ;; esac
  printf '%s' "$absolute_path"
}

# decision HOOK PAYLOAD CWD: allow, or deny:<status>, for one delivered payload.
decision() {
  local hook="$1" payload="$2" working_directory="$3"
  run --separate-stderr env PATH="$STUB_DIRECTORY:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$working_directory" "$payload" "$hook"
  if [ "$status" -eq 0 ] && ! grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
    printf 'allow'
  else
    printf 'deny:%s' "$status"
  fi
}

commit_payload() {
  jq -nc --arg working_directory "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "git commit -m \"change\""}, cwd: $working_directory}'
}

edit_payload() {
  jq -nc --arg working_directory "$1" --arg file_path "$2" \
    '{hook_event_name: "PreToolUse", tool_name: "Edit", tool_input: {file_path: $file_path, old_string: "1", new_string: "2"}, cwd: $working_directory}'
}

# check_commit_hook HOOK: control first, then the staged-test variant must
# decide the same as the control.
check_commit_hook() {
  local hook="$1" control variant
  control="$(decision "$hook" "$(commit_payload "$CONTROL_REPO")" "$CONTROL_REPO")"
  if [ "$control" != allow ]; then
    echo "control is not an allow for $hook: $control" >&2
    return 1
  fi
  variant="$(decision "$hook" "$(commit_payload "$TEST_REPO")" "$TEST_REPO")"
  if [ "$variant" != "$control" ]; then
    echo "$hook decides $variant on a staged test edit, $control on the control" >&2
    return 1
  fi
}

# check_edit_hook HOOK: the same for an Edit on a test file against an Edit on
# a non-test source file.
check_edit_hook() {
  local hook="$1" control variant
  control="$(decision "$hook" "$(edit_payload "$CONTROL_REPO" "$CONTROL_REPO/$SOURCE_FILE")" "$CONTROL_REPO")"
  if [ "$control" != allow ]; then
    echo "control is not an allow for $hook: $control" >&2
    return 1
  fi
  variant="$(decision "$hook" "$(edit_payload "$TEST_REPO" "$TEST_REPO/$TEST_FILE")" "$TEST_REPO")"
  if [ "$variant" != "$control" ]; then
    echo "$hook decides $variant on a test file edit, $control on the control" >&2
    return 1
  fi
}

# check_set KIND TOOLS...: derive the set, assert it is non-empty and matches
# the independent count, resolve every command, and run the per-hook check.
check_set() {
  local kind="$1" derived expected command hook seen=""
  shift
  derived="$(derive_set "$@")"
  expected="$(derived_count "$@")"
  [ -n "$derived" ] || { echo "empty $kind set" >&2; return 1; }
  [ "$(printf '%s\n' "$derived" | wc -l | tr -d ' ')" -eq "$expected" ] || { echo "$kind set size differs from the independent count $expected" >&2; return 1; }
  while IFS= read -r command; do
    hook="$(resolve_hook "$command")" || { echo "does not resolve to an executable hook under the repo: $command" >&2; return 1; }
    case " $seen " in *" $hook "*) continue ;; esac
    seen="$seen $hook"
    "check_${kind}_hook" "$hook" || return 1
  done <<<"$derived"
}

@test "no PreToolUse hook that can see a commit decides differently for a staged test edit" {
  check_set commit Bash
}

@test "no PreToolUse hook that can see an edit decides differently for a test file" {
  check_set edit Edit Write MultiEdit
}

@test "every derived registration resolves to an executable hook script under the repo root" {
  local command resolved_count=0
  while IFS= read -r command; do
    resolve_hook "$command" >/dev/null || { echo "unresolved: $command" >&2; return 1; }
    resolved_count=$((resolved_count + 1))
  done <<<"$(derive_set Bash Edit Write MultiEdit)"
  [ "$resolved_count" -gt 0 ]
}

@test "resolution rejects a command that does not have the rooted registration form" {
  run resolve_hook '"/tmp/elsewhere/.claude/hooks/nope.sh"'
  [ "$status" -ne 0 ]
  run resolve_hook '"$(git rev-parse --show-toplevel)/.claude/hooks/does-not-exist.sh"'
  [ "$status" -ne 0 ]
}

@test "red twin: a registered hook that denies a staged test path makes the check fail" {
  local twin_hook="$BATS_TEST_TMPDIR/twin-hook.sh" twin_settings="$BATS_TEST_TMPDIR/twin-settings.json" real_count twin_count
  cat >"$twin_hook" <<'HOOK'
#!/usr/bin/env bash
payload="$(cat)"
working_directory="$(printf '%s' "$payload" | jq -r '.cwd')"
if git -C "$working_directory" diff --cached --name-only | grep -q '\.test\.'; then
  printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "staged test"}}\n'
fi
exit 0
HOOK
  chmod +x "$twin_hook"
  jq --arg command "\"$twin_hook\"" \
    '.hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: $command}]}]' \
    "$REPO_ROOT/.claude/settings.json" >"$twin_settings"

  real_count="$(registered_commands "$REPO_ROOT/.claude/settings.json" Bash | wc -l | tr -d ' ')"
  twin_count="$(registered_commands "$twin_settings" Bash | wc -l | tr -d ' ')"
  [ "$twin_count" -eq $((real_count + 1)) ]
  [ "$(registered_commands "$twin_settings" Bash | tail -n 1)" = "\"$twin_hook\"" ]

  run check_commit_hook "$twin_hook"
  [ "$status" -ne 0 ]
  grep -qF -- 'decides deny' <<<"$output" || return 1
  return 0
}
