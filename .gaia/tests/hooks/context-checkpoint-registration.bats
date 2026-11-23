#!/usr/bin/env bats
#
# Registration of the context checkpoint hook in .claude/settings.json and the
# state registry entry that classifies its marker directory. The checkpoint must
# reach every tool of a main session, so it registers once, on PostToolUse, with
# no matcher; a matcher would silently narrow it to some tools and a second
# event would fire it twice.
#
# GAIA_REGISTRATION_SETTINGS and GAIA_REGISTRATION_REGISTRY point the cases at
# scratch copies; the red twins use the same assertion functions on a mutant.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/context-checkpoint-registration.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# The jq programs are single-quoted so their `$` reaches jq.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SETTINGS="${GAIA_REGISTRATION_SETTINGS:-$REPO_ROOT/.claude/settings.json}"
  REGISTRY="${GAIA_REGISTRATION_REGISTRY:-$REPO_ROOT/.gaia/state-registry.json}"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
}

# assert_registered SETTINGS: the hook is registered on PostToolUse and nowhere
# else, without a matcher.
assert_registered() {
  hook_registered "$1" '.hooks.PostToolUse[]' context-checkpoint-inject.sh
  run jq -e '[.hooks | to_entries[] | .key as $event | .value[] | .matcher as $m | .hooks[]
      | select(.command | test("context-checkpoint-inject[.]sh")) | [$event, $m]] == [["PostToolUse", null]]' "$1"
  [ "$status" -eq 0 ]
}

# assert_rooted_with_timeout SETTINGS: the sanctioned rooting prefix and a numeric
# timeout on the one registration.
assert_rooted_with_timeout() {
  run jq -e '[.hooks.PostToolUse[].hooks[] | select(.command | test("context-checkpoint-inject[.]sh"))] | length == 1
      and all(.[]; (.command | startswith("\"$(git rev-parse --show-toplevel")) and (.timeout | type == "number"))' "$1"
  [ "$status" -eq 0 ]
}

# assert_registry_entry REGISTRY: exactly one marker-directory entry, main-only,
# unkeyed, with a 7-day age reaper over regular files.
assert_registry_entry() {
  run jq -e '[.entries[] | select(.path == "cache/context-checkpoint/")] | length == 1
      and all(.[]; .scope == "main-only" and .keyed_by == null
      and .retention.class == "age" and .retention.days == 7 and .retention.types == ["file"])' "$1"
  [ "$status" -eq 0 ]
}

# --- settings -----------------------------------------------------------------

@test "the checkpoint hook is registered once, on PostToolUse, with no matcher" {
  assert_registered "$SETTINGS"
}

@test "the checkpoint registration uses the sanctioned rooting prefix and a numeric timeout" {
  assert_rooted_with_timeout "$SETTINGS"
}

# --- state registry -----------------------------------------------------------

@test "the state registry holds one main-only, unkeyed, reaped entry for the marker directory" {
  assert_registry_entry "$REGISTRY"
}

