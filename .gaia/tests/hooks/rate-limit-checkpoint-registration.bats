#!/usr/bin/env bats

# Registration of the rate-limit checkpoint hook in .claude/settings.json. It
# registers in its own PreToolUse entry on the dispatch tools and holds no other
# command, so the audit-loop entry that shares two of those tools stays as it
# was. GAIA_REGISTRATION_SETTINGS points the cases at a scratch copy; the red
# twins use the same assertion function on a mutant.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/rate-limit-checkpoint-registration.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# The jq programs are single-quoted so their `$` reaches jq.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SETTINGS="${GAIA_REGISTRATION_SETTINGS:-$REPO_ROOT/.claude/settings.json}"
}

# assert_registered_alone SETTINGS: one command names the hook, in a PreToolUse
# entry matching Agent|Task|Workflow that holds no other command, and the
# Agent|Task entry still runs only the audit-loop bound hook.
assert_registered_alone() {
  run jq -e '[.hooks | to_entries[] | .key as $event | .value[] | .matcher as $m | .hooks[]
      | select(.command | test("rate-limit-checkpoint-inject[.]sh")) | [$event, $m]] == [["PreToolUse", "Agent|Task|Workflow"]]' "$1"
  [ "$status" -eq 0 ]
  run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Agent|Task|Workflow")] | length == 1
      and (.[0].hooks | length == 1)
      and (.[0].hooks[0].timeout | type == "number")' "$1"
  [ "$status" -eq 0 ]
  run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Agent|Task")] | length == 1
      and (.[0].hooks | length == 1)
      and (.[0].hooks[0].command | test("audit-loop-bound[.]sh"))' "$1"
  [ "$status" -eq 0 ]
}

mutate_settings() {
  MUTANT="$BATS_TEST_TMPDIR/settings-mutant.json"
  jq "$1" "$SETTINGS" > "$MUTANT"
  if cmp -s "$MUTANT" "$SETTINGS"; then
    printf 'mutation did not change settings\n' >&2
    return 1
  fi
}

@test "the checkpoint hook registers alone on Agent, Task and Workflow and the audit-loop entry is unchanged" {
  assert_registered_alone "$SETTINGS"

  # Red: folding the hook into the audit-loop entry, and narrowing the matcher, each fail.
  mutate_settings '.hooks.PreToolUse |= map(select(.matcher != "Agent|Task|Workflow"))
    | (.hooks.PreToolUse[] | select(.matcher == "Agent|Task") | .hooks) += [{type: "command", command: "x/rate-limit-checkpoint-inject.sh"}]'
  run assert_registered_alone "$MUTANT"
  [ "$status" -ne 0 ]
  mutate_settings '(.hooks.PreToolUse[] | select(.matcher == "Agent|Task|Workflow") | .matcher) = "Agent|Task"'
  run assert_registered_alone "$MUTANT"
  [ "$status" -ne 0 ]
}
