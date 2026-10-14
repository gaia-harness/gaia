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
# unkeyed, with a reaper.
assert_registry_entry() {
  run jq -e '[.entries[] | select(.path == "cache/context-checkpoint/")] | length == 1
      and all(.[]; .scope == "main-only" and .keyed_by == null and .reaped_by != null)' "$1"
  [ "$status" -eq 0 ]
}

# mutate_settings JQ_PROGRAM: writes a scratch copy of settings.json transformed
# by the program, and leaves its path in MUTANT.
mutate_settings() {
  MUTANT="$BATS_TEST_TMPDIR/settings-mutant.json"
  jq "$1" "$SETTINGS" > "$MUTANT"
  if cmp -s "$MUTANT" "$SETTINGS"; then
    printf 'mutation did not change settings\n' >&2
    return 1
  fi
}

mutate_registry() {
  MUTANT="$BATS_TEST_TMPDIR/registry-mutant.json"
  jq "$1" "$REGISTRY" > "$MUTANT"
  if cmp -s "$MUTANT" "$REGISTRY"; then
    printf 'mutation did not change registry\n' >&2
    return 1
  fi
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

# --- red twins ------------------------------------------------------------------

@test "red twin: a matcher on the registration fails the registration check" {
  mutate_settings '(.hooks.PostToolUse[] | select(.hooks[].command | test("context-checkpoint-inject[.]sh"))) |= . + {matcher: "Bash"}'
  run assert_registered "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: removing the registration fails the registration check" {
  mutate_settings '.hooks.PostToolUse |= map(select(.hooks | all(.command | test("context-checkpoint-inject[.]sh") | not)))'
  run assert_registered "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: a second registration under SessionStart fails the registration check" {
  mutate_settings '.hooks.SessionStart += [{hooks: [{type: "command", command: "\"$(git rev-parse --show-toplevel 2>/dev/null || printf %s \"${CLAUDE_PROJECT_DIR:-.}\")/.claude/hooks/context-checkpoint-inject.sh\"", timeout: 10}]}]'
  run assert_registered "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: a command rooted on CLAUDE_PROJECT_DIR alone fails the sanctioned-prefix check" {
  mutate_settings '(.hooks.PostToolUse[].hooks[] | select(.command | test("context-checkpoint-inject[.]sh")) | .command) = "\"$CLAUDE_PROJECT_DIR/.claude/hooks/context-checkpoint-inject.sh\""'
  run assert_rooted_with_timeout "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: a missing timeout fails the sanctioned-prefix check" {
  mutate_settings 'del(.hooks.PostToolUse[].hooks[] | select(.command | test("context-checkpoint-inject[.]sh")) | .timeout)'
  run assert_rooted_with_timeout "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: removing the registry entry fails the registry check" {
  mutate_registry '.entries |= map(select(.path != "cache/context-checkpoint/"))'
  run assert_registry_entry "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: a null reaper fails the registry check" {
  mutate_registry '(.entries[] | select(.path == "cache/context-checkpoint/") | .reaped_by) = null'
  run assert_registry_entry "$MUTANT"
  [ "$status" -ne 0 ]
}
