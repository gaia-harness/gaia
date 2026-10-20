#!/usr/bin/env bats
#
# Registration of the sub-agent context checkpoint hook in both settings files,
# the state registry entry that classifies its marker directory, and its release
# inclusion. The hook must reach every tool
# of a sub-agent, so it registers once, on PostToolUse, with no matcher, in the
# group that holds the main-session checkpoint hook; a matcher would silently
# narrow it and a second event would fire it twice. A session launched in the
# frontend package reads only the generated file, so both files carry it.
#
# GAIA_REGISTRATION_SETTINGS, GAIA_REGISTRATION_FRONTEND_SETTINGS and
# GAIA_REGISTRATION_REGISTRY point the cases at scratch copies; the red twins
# use the same assertion functions on a mutant.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/context-checkpoint-subagent-registration.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# The jq programs are single-quoted so their `$` reaches jq.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SETTINGS="${GAIA_REGISTRATION_SETTINGS:-$REPO_ROOT/.claude/settings.json}"
  FRONTEND_SETTINGS="${GAIA_REGISTRATION_FRONTEND_SETTINGS:-$REPO_ROOT/frontend/.claude/settings.json}"
  REGISTRY="${GAIA_REGISTRATION_REGISTRY:-$REPO_ROOT/.gaia/state-registry.json}"
  EXCLUDE="$REPO_ROOT/.gaia/release-exclude"
  HOOK_PATH='.claude/hooks/context-checkpoint-subagent.sh'
  DOCTRINE_PATH='.claude/doctrine/context-yield.md'
  HANDOFF_CLEAR_ALLOW='Bash(bash .gaia/scripts/spec/handoff-clear.sh:*)'
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
}

# assert_registered SETTINGS: the hook is registered on PostToolUse and nowhere
# else, without a matcher, in the group that also holds the main-session hook.
assert_registered() {
  # Inside `run assert_registered`, errexit is off, so each step returns on its own failure.
  hook_registered "$1" '.hooks.PostToolUse[]' context-checkpoint-subagent.sh || return 1
  jq -e '[.hooks | to_entries[] | .key as $event | .value[] | .matcher as $m | .hooks[]
      | select(.command | test("context-checkpoint-subagent[.]sh")) | [$event, $m]] == [["PostToolUse", null]]' "$1" >/dev/null || return 1
  jq -e '[.hooks.PostToolUse[]
      | select(any(.hooks[]; .command | test("context-checkpoint-subagent[.]sh")))
      | select(any(.hooks[]; .command | test("context-checkpoint-inject[.]sh")))] | length == 1' "$1" >/dev/null || return 1
}

# assert_rooted_with_timeout SETTINGS: the sanctioned rooting prefix and a numeric
# timeout on the one registration.
assert_rooted_with_timeout() {
  run jq -e '[.hooks.PostToolUse[].hooks[] | select(.command | test("context-checkpoint-subagent[.]sh"))] | length == 1
      and all(.[]; (.command | startswith("\"$(git rev-parse --show-toplevel")) and (.timeout | type == "number"))' "$1"
  [ "$status" -eq 0 ]
}

# assert_handoff_clear_allowed SETTINGS: the dispatcher's handoff pre-clear is
# allowed exactly once, so dispatches do not prompt.
assert_handoff_clear_allowed() {
  run jq -e --arg entry "$HANDOFF_CLEAR_ALLOW" '[.permissions.allow[] | select(. == $entry)] | length == 1' "$1"
  [ "$status" -eq 0 ]
}

# assert_registry_entry REGISTRY: exactly one marker-directory entry, main-only,
# unkeyed, age-reaped, and explained by the hook that writes it.
assert_registry_entry() {
  run jq -e '[.entries[] | select(.path == "cache/context-checkpoint-agents/")] | length == 1
      and all(.[]; .scope == "main-only" and .keyed_by == null
        and .retention.class == "age" and .retention.days == 7 and .retention.types == ["file"]
        and (.why | contains("context-checkpoint-subagent.sh")))' "$1"
  [ "$status" -eq 0 ]
}

# assert_not_excluded EXCLUDE_FILE PATH: no exclusion line covers the path, by
# the matcher the release build uses (exact line or directory prefix).
assert_not_excluded() {
  local exclude="$1" path="$2" line
  [ -f "$exclude" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    line="${line%/}"
    [ -n "$line" ] || continue
    case "$path" in
      "$line" | "$line"/*) return 1 ;;
    esac
  done <"$exclude"
  return 0
}

# mutate_json SOURCE JQ_PROGRAM: writes a scratch copy of SOURCE transformed by
# the program, and leaves its path in MUTANT.
mutate_json() {
  MUTANT="$BATS_TEST_TMPDIR/mutant-$(basename "$1")"
  jq "$2" "$1" > "$MUTANT"
  if cmp -s "$MUTANT" "$1"; then
    printf 'mutation did not change %s\n' "$1" >&2
    return 1
  fi
}

# --- settings, both files -----------------------------------------------------

@test "the sub-agent hook is registered once, on PostToolUse, with no matcher, beside the main-session hook" {
  assert_registered "$SETTINGS"
  assert_registered "$FRONTEND_SETTINGS"
}

@test "the sub-agent registration uses the sanctioned rooting prefix and a numeric timeout" {
  assert_rooted_with_timeout "$SETTINGS"
  assert_rooted_with_timeout "$FRONTEND_SETTINGS"
}

@test "both settings files allow the handoff pre-clear script exactly once" {
  assert_handoff_clear_allowed "$SETTINGS"
  assert_handoff_clear_allowed "$FRONTEND_SETTINGS"
}

# --- state registry -----------------------------------------------------------

@test "the state registry holds one main-only, unkeyed, reaped entry naming the hook for the marker directory" {
  assert_registry_entry "$REGISTRY"
}

# --- release inclusion --------------------------------------------------------

@test "neither the hook nor the doctrine file is release-excluded" {
  assert_not_excluded "$EXCLUDE" "$HOOK_PATH"
  assert_not_excluded "$EXCLUDE" "$DOCTRINE_PATH"
}

# --- red twins ------------------------------------------------------------------

@test "red twin: removing the registration fails the registration check" {
  mutate_json "$SETTINGS" '.hooks.PostToolUse |= map(.hooks |= map(select(.command | test("context-checkpoint-subagent[.]sh") | not)))'
  run assert_registered "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: a duplicate registration under PostToolUse fails the registration check" {
  mutate_json "$SETTINGS" '.hooks.PostToolUse += [{hooks: [{type: "command", command: "\"$(git rev-parse --show-toplevel 2>/dev/null || printf %s \"${CLAUDE_PROJECT_DIR:-.}\")/.claude/hooks/context-checkpoint-subagent.sh\"", timeout: 10}]}]'
  run assert_registered "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: a second registration under SessionStart fails the registration check" {
  mutate_json "$SETTINGS" '.hooks.SessionStart += [{hooks: [{type: "command", command: "\"$(git rev-parse --show-toplevel 2>/dev/null || printf %s \"${CLAUDE_PROJECT_DIR:-.}\")/.claude/hooks/context-checkpoint-subagent.sh\"", timeout: 10}]}]'
  run assert_registered "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: a matcher on the registration fails the registration check" {
  mutate_json "$SETTINGS" '(.hooks.PostToolUse[] | select(any(.hooks[]; .command | test("context-checkpoint-subagent[.]sh")))) |= . + {matcher: "Bash"}'
  run assert_registered "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: a registration outside the main-session hook's group fails the registration check" {
  mutate_json "$SETTINGS" '(.hooks.PostToolUse |= map(.hooks |= map(select(.command | test("context-checkpoint-subagent[.]sh") | not)))) | .hooks.PostToolUse += [{hooks: [{type: "command", command: "\"$(git rev-parse --show-toplevel 2>/dev/null || printf %s \"${CLAUDE_PROJECT_DIR:-.}\")/.claude/hooks/context-checkpoint-subagent.sh\"", timeout: 10}]}]'
  run assert_registered "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: a command rooted on CLAUDE_PROJECT_DIR alone fails the sanctioned-prefix check" {
  mutate_json "$SETTINGS" '(.hooks.PostToolUse[].hooks[] | select(.command | test("context-checkpoint-subagent[.]sh")) | .command) = "\"$CLAUDE_PROJECT_DIR/.claude/hooks/context-checkpoint-subagent.sh\""'
  run assert_rooted_with_timeout "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: a non-numeric timeout fails the sanctioned-prefix check" {
  mutate_json "$SETTINGS" '(.hooks.PostToolUse[].hooks[] | select(.command | test("context-checkpoint-subagent[.]sh")) | .timeout) = "10"'
  run assert_rooted_with_timeout "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: removing the handoff pre-clear allowance fails the allowance check" {
  mutate_json "$SETTINGS" '.permissions.allow |= map(select(. != "Bash(bash .gaia/scripts/spec/handoff-clear.sh:*)"))'
  run assert_handoff_clear_allowed "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: removing the registry entry fails the registry check" {
  mutate_json "$REGISTRY" '.entries |= map(select(.path != "cache/context-checkpoint-agents/"))'
  run assert_registry_entry "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: a why that does not name the hook fails the registry check" {
  mutate_json "$REGISTRY" '(.entries[] | select(.path == "cache/context-checkpoint-agents/") | .why) = "Per-agent marker."'
  run assert_registry_entry "$MUTANT"
  [ "$status" -ne 0 ]
}

@test "red twin: the hook path in the exclusions fails the exclusion check" {
  { cat "$EXCLUDE"; printf '%s\n' "$HOOK_PATH"; } > "$BATS_TEST_TMPDIR/exclude-hook"
  run assert_not_excluded "$BATS_TEST_TMPDIR/exclude-hook" "$HOOK_PATH"
  [ "$status" -ne 0 ]
}

@test "red twin: the doctrine directory in the exclusions fails the exclusion check" {
  { cat "$EXCLUDE"; printf '.claude/doctrine\n'; } > "$BATS_TEST_TMPDIR/exclude-doctrine"
  run assert_not_excluded "$BATS_TEST_TMPDIR/exclude-doctrine" "$DOCTRINE_PATH"
  [ "$status" -ne 0 ]
}

