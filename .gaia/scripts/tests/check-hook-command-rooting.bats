#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-hook-command-rooting.sh.
#
# .claude/settings.json registers every hook as a command string that
# /bin/sh runs against the Bash tool's current working directory, which
# persists for the whole session. A command naming its script by a
# repo-relative path therefore resolves against wherever the session last
# stood, so a single `cd` unregisters the layer: the script is not found,
# /bin/sh exits 127, and per wiki/concepts/Claude Hooks.md only exit 2
# blocks. 127 is neither 0 nor 2, so the tool call proceeds and the guard
# layer fails OPEN. That is #1740, observed end to end.
#
# This suite IS the gate for the registration file: nothing else in the
# repo asserts that a hook command resolves independently of cwd, so the
# "real repo" test below is what actually fails a build when an unrooted
# registration lands.
#
# What the check can and cannot do is a decided residual, not an
# oversight. It reads the file, so it catches an unrooted registration in
# the file. It cannot catch a root that fails to resolve at runtime,
# because nothing at the registration site can fail closed: a hook that is
# not found exits 127 and 127 does not block. The static check is the only
# instrument that can hold the class down, and it holds down the half that
# lives in the file.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-hook-command-rooting.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIRECTORY/check-hook-command-rooting.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-hook-command-rooting.sh
  source "$CHECK"
}

# Every fixture root below is created under $BATS_TEST_TMPDIR, which bats
# removes after each test. An earlier revision collected the roots in a
# FIXTURE_DIRS array for a teardown to delete, which cannot work: the helper
# is always called as `$(fixture_with ...)`, so its body runs in a subshell
# and the array the teardown read was always empty. Letting bats own the
# lifetime removes the class rather than repairing one instance of it.

# fixture_with <command-json-array-of-strings> -> echoes a repo root whose
# .claude/settings.json registers exactly those commands, one hook each.
fixture_with() {
  local commands_json="$1" fixture_directory
  fixture_directory="$(mktemp -d "$BATS_TEST_TMPDIR/fixture.XXXXXX")"
  mkdir -p "$fixture_directory/.claude"
  jq -n --argjson commands "$commands_json" '{
    hooks: {
      PreToolUse: [ { matcher: "Bash",
                      hooks: [ $commands[] | { type: "command", command: . } ] } ]
    }
  }' > "$fixture_directory/.claude/settings.json"
  printf '%s\n' "$fixture_directory"
}

@test "a rooted command, or one naming no path, passes" {
  local commands_json root
  for commands_json in \
    '["\"$(git rev-parse --show-toplevel 2>/dev/null || printf %s \"${CLAUDE_PROJECT_DIR:-.}\")/.claude/hooks/block-rm-rf.sh\""]' \
    '["/opt/gaia/.claude/hooks/block-rm-rf.sh"]' \
    '["echo hi"]'; do
    root="$(fixture_with "$commands_json")"
    run gaia_check_hook_command_rooting "$root"
    [ "$status" -eq 0 ] || { echo "commands $commands_json: status $status"; return 1; }
  done
}

# bats test_tags=protected
@test "a bare repo-relative command is caught" {
  local row commands_json named unnamed root
  for row in \
    '[".claude/hooks/block-rm-rf.sh"]|block-rm-rf.sh|' \
    '["bash .gaia/statusline/gaia-statusline.sh"]|gaia-statusline.sh|' \
    '["\"$(git rev-parse --show-toplevel)/.claude/hooks/a.sh\"", ".claude/hooks/b.sh", "/abs/.claude/hooks/c.sh"]|b.sh|a.sh'; do
    IFS='|' read -r commands_json named unnamed <<<"$row"
    root="$(fixture_with "$commands_json")"
    run gaia_check_hook_command_rooting "$root"
    [ "$status" -ne 0 ] || { echo "row $named: passed"; return 1; }
    grep -qF -- "$named" <<<"$output" || { echo "row $named: not named in the report"; return 1; }
    # A rooted sibling must not be reported beside the unrooted one.
    if [ -n "$unnamed" ]; then
      grep -qF -- "$unnamed" <<<"$output" && { echo "row $named: reported rooted $unnamed"; return 1; }
    fi
  done
  return 0
}

@test "an empty command set or a missing settings.json is a failure, never a pass" {
  local fixture_directory
  fixture_directory="$(mktemp -d "$BATS_TEST_TMPDIR/fixture.XXXXXX")"
  mkdir -p "$fixture_directory/.claude"
  printf '%s\n' '{"hooks":{}}' > "$fixture_directory/.claude/settings.json"
  run gaia_check_hook_command_rooting "$fixture_directory"
  [ "$status" -ne 0 ] || { echo "empty command set passed"; return 1; }

  fixture_directory="$(mktemp -d "$BATS_TEST_TMPDIR/fixture.XXXXXX")"
  run gaia_check_hook_command_rooting "$fixture_directory"
  [ "$status" -ne 0 ]
}


# Coverage is per element: the set is derived from the artifact that owns it
# (.claude/settings.json) rather than restated here, and every derived command
# is asserted.
#
# The cross-count below is narrower than it looks and the comment says so
# rather than overclaiming. Both sides build the array with the same jq
# expression, so what the pair establishes is that
# `gaia_hook_command_rooting_commands` has not drifted from the expression
# this suite pins, plus that no command is an empty string or carries an
# embedded newline. A registration shape the expression itself misses is
# invisible on BOTH sides and this pair cannot see it.
@test "real repo: every registered command in settings.json is rooted" {
  local settings derived_count file_count
  settings="$REPO_ROOT/.claude/settings.json"
  [ -f "$settings" ]

  # What the derivation found...
  derived_count="$(gaia_hook_command_rooting_commands "$settings" | grep -c .)"
  # ...against what the file actually holds, counted independently.
  file_count="$(jq '[(.hooks // {} | .[][].hooks[].command), (.statusLine.command // empty)] | length' "$settings")"

  [ "$derived_count" -eq "$file_count" ]
  [ "$derived_count" -gt 0 ]

  run gaia_check_hook_command_rooting "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

