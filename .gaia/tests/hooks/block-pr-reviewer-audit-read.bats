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
