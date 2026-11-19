#!/usr/bin/env bats

# Tests for .claude/hooks/block-settings-write.sh.
#
# `.claude/settings.json` registers every GAIA hook and permission rule. This
# guard asks the operator (never denies) when a Bash or Monitor command writes
# it through a redirect, tee, sponge, sed -i, or a cp/mv destination, and stays
# silent for reads, other files and the edit tools (a permissions.ask rule
# covers those). The decision is JSON on stdout carrying "ask" (mechanism 3 in
# helpers/run-hook.sh); the hook always exits 0 except when a library is missing,
# or jq is missing and the command names settings.json.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/tests/hooks/block-settings-write.bats`.
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/path.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-settings-write.sh"
  # shellcheck disable=SC2088 # The literal tilde is the command text under test.
  GUARDED_PATHS=(
    ".claude/settings.json"
    "./.claude/settings.json"
    "/Users/you/app/.claude/settings.json"
    "apps/web/.claude/settings.json"
    ".claude/worktrees/w1/.claude/settings.json"
    "\"/Users/you/my app/.claude/settings.json\""
    "~/.claude/settings.json"
  )
  # Each shape holds the literal PATH, replaced by the guarded path.
  WRITE_SHAPES=(
    "sed -i 's/a/b/' PATH"
    "sed -i '' 's/a/b/' PATH"
    "echo '{}' > PATH"
    "echo '{}' >> PATH"
    "echo x | tee PATH"
    "echo x | tee -a PATH"
    "jq . x.json | sponge PATH"
    "cp /tmp/src.json PATH"
    "mv /tmp/src.json PATH"
    "cp /tmp/src.json PATH 2>/dev/null"
    "cp /tmp/src.json PATH 2> /dev/null"
    "mv /tmp/src.json PATH >/dev/null 2>&1"
    "jq '.a = 1' PATH > /tmp/tmp.json && mv /tmp/tmp.json PATH"
    $'echo \'line one\nline two\' > PATH'
    $'jq \'.a = 1\n| .b = 2\' x.json > /tmp/tmp.json && mv /tmp/tmp.json PATH'
    $'jq \'.a = 1\n| .b = 2\' PATH > /tmp/tmp.json\nmv /tmp/tmp.json PATH'
    "echo it's > PATH"
    $'jq \'.a = 1\n| .b = 2\' x.json > /tmp/tmp.json && mv /tmp/tmp.json PATH && echo \'two words\''
    $'cp /tmp/src.json \\\n  PATH'
    $'mv /tmp/src.json \\\n  PATH'
    $'sed -i \'s/a/b/\' \\\n  PATH'
    $'echo x | tee \\\n  PATH'
    $'echo x > \\\n  PATH'
    "echo x > PATH; echo done"
    "echo x > PATH&& echo done"
    "echo x > PATH|| echo failed"
    "echo x > PATH| cat"
    "echo x > PATH& wait"
    "(echo x > PATH)"
    "cp /tmp/src.json PATH; echo done"
    "mv /tmp/src.json PATH&& echo done"
    "(cd /tmp && cp /tmp/src.json PATH)"
    "sed -i 's/a/b/' PATH; echo done"
    "echo x | tee PATH; echo done"
    "echo x | tee PATH| cat"
    $'jq \'.a = 1\n| .b = 2\n\' x.json > /tmp/tmp.json && mv /tmp/tmp.json PATH && echo \'two words\''
    $'jq ".a = 1\n| .b = 2\n" x.json > /tmp/tmp.json && mv /tmp/tmp.json PATH && echo "two words"'
    $'echo \'tis the season\nmv /tmp/tmp.json PATH'
    "cp /tmp/src.json PATH >& /dev/null"
    "( mv /tmp/src.json PATH )"
    "cp /tmp/src.json PATH & wait"
    "cp /tmp/src.json PATH # restore"
    "echo x >PATH"
    $'sed -i \'s/a/b/\n s/c/d/\' PATH'
    $'cp \'/tmp/a\n b.json\' PATH'
    "echo x >>PATH"
  )
}

run_hook_command() {
  local tool_name="$1" command_line="$2"
  local json
  json=$(jq -n --arg tool_name "$tool_name" --arg command "$command_line" '{tool_name: $tool_name, tool_input: {command: $command}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# Asserts the run is a well-formed ask carrying the full reason.
assert_settings_ask() {
  local needle
  [ "$status" -eq 0 ] || return 1
  jq -e -s 'length == 1' <<<"$output" >/dev/null || return 1
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' <<<"$output" >/dev/null || return 1
  jq -e '.hookSpecificOutput.permissionDecision == "ask"' <<<"$output" >/dev/null || return 1
  for needle in '.claude/settings.json' 'asks on the target alone' 'Approve only a change you meant' 'do not retry this write by another route'; do
    jq -e --arg needle "$needle" '.hookSpecificOutput.permissionDecisionReason | contains($needle)' <<<"$output" >/dev/null || return 1
  done
}

# --- asks: the write matrix ---

# bats test_tags=protected
@test "Bash and Monitor writes of a settings.json path ask, for every path and shape" {
  local tool_name guarded_path shape command_line
  for tool_name in Bash Monitor; do
    for guarded_path in "${GUARDED_PATHS[@]}"; do
      for shape in "${WRITE_SHAPES[@]}"; do
        command_line="${shape//PATH/$guarded_path}"
        run_hook_command "$tool_name" "$command_line"
        if ! assert_settings_ask; then
          printf 'did not ask: tool=%s path=%s shape=%s\n' "$tool_name" "$guarded_path" "$shape" >&2
          return 1
        fi
      done
    done
  done
}

@test "the manifest-write exemption marker does not exempt a settings write" {
  local tool_name
  for tool_name in Bash Monitor; do
    run_hook_command "$tool_name" "GAIA_MANIFEST_WRITE=1 cp /tmp/src.json .claude/settings.json"
    if ! assert_settings_ask; then
      printf 'did not ask: tool=%s\n' "$tool_name" >&2
      return 1
    fi
  done
}

# --- passes silently ---

# An Edit row passes its input as file_path: the permissions.ask rule covers the
# file tools, so the hook stays silent for them.
@test "reads, other-file writes and edit-tool payloads pass silently" {
  local row tool_name command_line json
  for row in \
    "Bash|cat .claude/settings.json" \
    "Bash|jq . .claude/settings.json" \
    "Bash|cp .claude/settings.json /tmp/x" \
    "Bash|cat .claude/settings.json | tee /tmp/x" \
    "Bash|sed -n p .claude/settings.json" \
    "Bash|echo x > apps/web/package.json" \
    "Bash|echo x > .claude/settings.json.bak" \
    "Bash|sed -i s/a/b/ .claude/settings.local.json" \
    "Bash|cp a .claude/settings.local.json" \
    $'Bash|cp .claude/settings.json \\\n  /tmp/x' \
    "Bash|cat .claude/settings.json; echo done" \
    "Bash|cp .claude/settings.json /tmp/x; echo done" \
    "Bash|echo x > .claude/settings.json.bak; echo done" \
    "Bash|(cat .claude/settings.json)" \
    "Bash|cp .claude/settings.json /tmp/x >& /dev/null" \
    $'Bash|jq \'.a\n| .b\' .claude/settings.json > /tmp/x' \
    "Monitor|cat .claude/settings.json" \
    "Monitor|echo x > .claude/settings.json.bak" \
    "Edit|.claude/settings.json"; do
    tool_name=${row%%|*}; command_line=${row#*|}
    if [ "$tool_name" = Edit ]; then
      json=$(jq -n --arg file_path "$command_line" '{tool_name: "Edit", tool_input: {file_path: $file_path}}')
      invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
    else
      run_hook_command "$tool_name" "$command_line"
    fi
    if [ "$status" -ne 0 ] || [ -n "$output" ]; then
      printf 'not silent: tool=%s input=%s status=%s output=%s\n' "$tool_name" "$command_line" "$status" "$output" >&2
      return 1
    fi
  done
}

# --- fail loud: a missing library refuses rather than failing open ---

@test "a missing library makes the hook exit 2, one per library" {
  local library scratch json
  json=$(jq -n --arg command 'echo x > .claude/settings.json' '{tool_name: "Bash", tool_input: {command: $command}}')
  for library in jq-availability.sh hook-payload.sh bash-write-target.sh; do
    scratch="$BATS_TEST_TMPDIR/missing-${library%.sh}"
    mkdir -p "$scratch"
    cp -R "$HOOKS_SOURCE_DIRECTORY/lib" "$scratch/lib"
    cp "$HOOK_ABSOLUTE_PATH" "$scratch/block-settings-write.sh"
    rm "$scratch/lib/$library"
    invoke_hook "$json" "$scratch/block-settings-write.sh"
    if [ "$status" -ne 2 ] || ! grep -qF -- "cannot load lib/$library" <<<"$output"; then
      printf 'did not refuse loudly without %s (status %s)\n' "$library" "$status" >&2
      return 1
    fi
  done
}

# --- jq absent ---

without_jq() {
  export PATH
  PATH="$(path_shim_without jq)"
  [ -z "$(command -v jq)" ]
  invoke_hook "$1" "$HOOK_ABSOLUTE_PATH"
}

@test "jq absent: a settings write is refused, an unrelated command exits 0" {
  local settings_write_json unrelated_json
  # Both payloads are built before without_jq strips jq from PATH.
  settings_write_json=$(jq -n --arg command 'echo x > .claude/settings.json' '{tool_name: "Bash", tool_input: {command: $command}}')
  unrelated_json=$(jq -n --arg command 'echo hello' '{tool_name: "Bash", tool_input: {command: $command}}')
  without_jq "$settings_write_json"
  [ "$status" -eq 2 ] || { echo "case settings-write: status=$status, expected 2"; return 1; }
  without_jq "$unrelated_json"
  [ "$status" -eq 0 ] || { echo "case unrelated: status=$status, expected 0"; return 1; }
}
