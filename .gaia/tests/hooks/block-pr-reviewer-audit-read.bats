#!/usr/bin/env bats
#
# Tests for .claude/hooks/block-pr-reviewer-audit-read.sh. The hook denies the
# pr-reviewer agent a read of audit state and lets every other caller through.
# The deny is JSON on stdout.
#
# Maintainer-only: `.gaia/tests` is release-excluded.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOK_ABSOLUTE_PATH="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/block-pr-reviewer-audit-read.sh"
}

# payload <tool> <tool-input-json> [agent-type]: a hook payload; with no
# agent type the call is the main thread's and carries no agent fields.
payload() {
  if [ -n "${3-}" ]; then
    jq -n -c --arg tool "$1" --argjson input "$2" --arg type "$3" \
      '{tool_name: $tool, tool_input: $input, agent_id: "agent-1", agent_type: $type}'
  else
    jq -n -c --arg tool "$1" --argjson input "$2" '{tool_name: $tool, tool_input: $input}'
  fi
}

# bats test_tags=protected
@test "the reviewer is denied audit-state reads and every other caller is allowed" {
  # The reviewer reads an audit findings file.
  invoke_hook "$(payload Read '{"file_path":".gaia/local/audit/abc.findings.json"}' pr-reviewer)" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json || return 1
  grep -qF 'BLOCKED: pr-reviewer may not read audit state: .gaia/local/audit/abc.findings.json' <<<"$output" || return 1

  # The reviewer cats a run-folder file through Bash.
  invoke_hook "$(payload Bash '{"command":"cat .gaia/local/runs/feat+x/unit-1.json"}' pr-reviewer)" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json || return 1
  grep -qF 'BLOCKED: pr-reviewer may not read audit state: .gaia/local/runs/feat+x/unit-1.json' <<<"$output" || return 1

  # The reviewer reads an ordinary source file.
  invoke_hook "$(payload Read '{"file_path":".gaia/scripts/a.sh"}' pr-reviewer)" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json || return 1

  # The same audit path from the main thread (no agent_type).
  invoke_hook "$(payload Read '{"file_path":".gaia/local/audit/abc.findings.json"}')" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json || return 1

  # The same audit path from another agent type.
  invoke_hook "$(payload Read '{"file_path":".gaia/local/audit/abc.findings.json"}' code-audit-shell)" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json
}

@test "the reviewer is denied a dot-segment, doubled-slash or folded spelling of the audit folders, and a deny names what to search instead" {
  local spelling
  for spelling in '.gaia/local/./runs/x' '.gaia//local/runs/x' '.gaia/local/cache/../audit/x' './.gaia/local/audit/x' '/repo/.gaia/local/./runs/x'; do
    invoke_hook "$(payload Read "$(jq -n -c --arg path "$spelling" '{file_path: $path}')" pr-reviewer)" "$HOOK_ABSOLUTE_PATH"
    assert_denied_by_json || { echo "Read allowed: $spelling" >&2; return 1; }
    invoke_hook "$(payload Bash "$(jq -n -c --arg command "cat $spelling" '{command: $command}')" pr-reviewer)" "$HOOK_ABSOLUTE_PATH"
    assert_denied_by_json || { echo "Bash allowed: $spelling" >&2; return 1; }
  done

  # A search whose pattern merely names the folders is denied, and the line says where to search.
  invoke_hook "$(payload Bash '{"command":"git grep -n .gaia/local/runs -- .gaia/scripts"}' pr-reviewer)" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json || return 1
  grep -qF "search the bundle's diff.patch or the changed files instead" <<<"$output" || return 1

  # Paths that merely look similar stay allowed, and so does a leading ../ with nothing to fold.
  invoke_hook "$(payload Read '{"file_path":".gaia/local-notes/runs/x"}' pr-reviewer)" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json || return 1
  invoke_hook "$(payload Read '{"file_path":"../../apps/web/a.ts"}' pr-reviewer)" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json || return 1
}

# reviewer_command <command> <cwd>: a reviewer Bash payload whose working directory is
# this checkout, so a `.` operand resolves to a folder that holds the state root.
reviewer_command() {
  jq -n -c --arg command "$1" --arg cwd "$2" \
    '{tool_name: "Bash", tool_input: {command: $command}, cwd: $cwd, agent_id: "agent-1", agent_type: "pr-reviewer"}'
}

@test "the reviewer is denied a cd into the state root and a recursive search that would read it, whatever the short-option cluster" {
  local checkout command
  checkout="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  for command in \
    'cd .gaia/local && cat runs/feat+x/unit-1.json' \
    'cd .gaia; ls' \
    'pushd .gaia/local' \
    'grep -r stop_reason .gaia' \
    'grep -R stop_reason .gaia' \
    'grep -rn stop_reason .gaia/' \
    'grep -nr stop_reason .gaia/local' \
    'grep --recursive stop_reason .gaia' \
    'ls -R .gaia' \
    'rg stop_reason .gaia' \
    'find .gaia -name "*.json"' \
    'grep -rn stop_reason .'; do
    invoke_hook "$(reviewer_command "$command" "$checkout")" "$HOOK_ABSOLUTE_PATH"
    assert_denied_by_json || { echo "Bash allowed: $command" >&2; return 1; }
  done

  # A search of the changed files, a search that excludes the state root, and a cd elsewhere stay allowed.
  for command in \
    'grep -rn stop_reason apps' \
    'grep -n stop_reason .gaia/scripts/a.sh' \
    "grep -rn stop_reason . --exclude-dir=.gaia" \
    'ls -la .gaia/scripts' \
    'cd apps/web && ls'; do
    invoke_hook "$(reviewer_command "$command" "$checkout")" "$HOOK_ABSOLUTE_PATH"
    assert_allowed_by_json || { echo "Bash denied: $command" >&2; return 1; }
  done

  # The same recursive search from the main thread is not the reviewer's to be denied.
  invoke_hook "$(jq -n -c '{tool_name: "Bash", tool_input: {command: "grep -r x .gaia"}}')" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json
}

# bats test_tags=protected
@test "the reviewer is denied with the BLOCKED line for a cd or recursive search of audit state, writes nothing, and a non-reviewer is allowed" {
  local checkout command before after
  checkout="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  before="$(git -C "$checkout" status --porcelain --untracked-files=all 2>/dev/null | sort | md5sum)"
  for command in \
    'cd .gaia/local && cat runs/feat+x/unit-1.json' \
    'pushd .gaia' \
    'grep -r stop_reason .gaia' \
    'grep -R x .gaia/local' \
    'grep -rn x .' \
    'ls -R .gaia' \
    'rg x .gaia' \
    "find .gaia -name '*.json'"; do
    invoke_hook "$(reviewer_command "$command" "$checkout")" "$HOOK_ABSOLUTE_PATH"
    assert_denied_by_json || { echo "Bash allowed: $command" >&2; return 1; }
    grep -qF 'BLOCKED: pr-reviewer may not read audit state:' <<<"$output" || { echo "No BLOCKED line: $command" >&2; return 1; }
  done
  after="$(git -C "$checkout" status --porcelain --untracked-files=all 2>/dev/null | sort | md5sum)"
  [ "$before" = "$after" ] || return 1

  # The same recursive search without the reviewer agent type is allowed.
  invoke_hook "$(jq -n -c --arg cwd "$checkout" '{tool_name: "Bash", tool_input: {command: "grep -r stop_reason .gaia"}, cwd: $cwd}')" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json
}
