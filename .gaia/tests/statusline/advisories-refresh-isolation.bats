#!/usr/bin/env bats

# The advisory lookup runs only inside the detached background refresh. The
# statusline render path never reaches the network, and no SessionStart hook
# starts the refresher or the advisories verb.
#
# Run via: bash .gaia/scripts/bats5.sh .gaia/tests/statusline/advisories-refresh-isolation.bats < /dev/null

setup() {
  GAIA_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STATUSLINE_FILE="$GAIA_ROOT/.gaia/statusline/gaia-statusline.sh"
  SETTINGS_FILE="$GAIA_ROOT/.claude/settings.json"
  command -v jq >/dev/null 2>&1 || skip "jq required"
}

# Prints each offending line of the statusline: a network or advisory token
# on a line that is not part of the CHECK_SCRIPT launch.
statusline_offenders() {
  grep -nE 'dependabot/alerts|pnpm audit|gh api|advisories' "$1" | grep -v 'CHECK_SCRIPT' || true
}

# Prints each SessionStart command naming the refresher or the verb.
session_start_offenders() {
  jq -r '(.hooks.SessionStart // [])[] | .hooks[]? | .command // empty' "$1" | grep -E 'check-updates|advisories' || true
}

@test "the statusline holds no advisory or network token outside the refresher launch" {
  [ -s "$STATUSLINE_FILE" ]
  grep -q 'CHECK_SCRIPT' "$STATUSLINE_FILE"
  [ -z "$(statusline_offenders "$STATUSLINE_FILE")" ]
}

@test "no SessionStart command names the refresher or the advisories verb" {
  [ -s "$SETTINGS_FILE" ]
  jq -e '.hooks.SessionStart | length > 0' "$SETTINGS_FILE" >/dev/null
  [ -z "$(session_start_offenders "$SETTINGS_FILE")" ]
}
