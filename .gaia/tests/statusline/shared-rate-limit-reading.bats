#!/usr/bin/env bats
#
# Flow test: every session's GAIA left side shows the freshest rate-limit
# reading of its checkout, merged from all sessions. One session in the main
# checkout and one in a linked worktree render through the real statusline
# entry point; the worktree session, reporting a lower figure for the same
# window, shows the main session's higher one, and the reader prints the window.
# Colors, history, merge edge cases and refusals are owned by the
# rate-limits-display suite and the library suite.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/statusline/shared-rate-limit-reading.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

NOW=1795440000

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STATUSLINE="$REPO_ROOT/.gaia/statusline/gaia-statusline.sh"
  CLI="$REPO_ROOT/.gaia/scripts/rate-limits.sh"
  ESCAPE_CHARACTER=$'\033'
  SEVEN_DAY_RESETS_AT=$((NOW + 187230))
  MAIN="$BATS_TEST_TMPDIR/main"
  WORKTREE="$BATS_TEST_TMPDIR/worktree"
  TEMPORARY_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$MAIN/.gaia/local" "$TEMPORARY_HOME"
  git -C "$MAIN" init -q --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  echo x >"$MAIN/README.md"
  git -C "$MAIN" add README.md
  git -C "$MAIN" commit -q -m init
  git -C "$MAIN" worktree add -q "$WORKTREE" -b feature
  printf '{"version":1,"statusline":{"left":"gaia"}}' >"$MAIN/.gaia/local/settings.json"
  export TZ=UTC
}

# render <cwd> <seven_day percentage>: one session's render, ANSI stripped into
# PLAIN_OUTPUT.
render() {
  local cwd="$1" percentage="$2" json
  json=$(jq -n --arg current_directory "$cwd" --argjson percentage "$percentage" --argjson resets_at "$SEVEN_DAY_RESETS_AT" \
    '{workspace: {current_dir: $current_directory}, model: {display_name: "Claude Opus"}, effort: {level: "xhigh"},
      context_window: {used_percentage: 21, context_window_size: 1000000},
      rate_limits: {seven_day: {used_percentage: $percentage, resets_at: $resets_at}}}')
  PAYLOAD="$json" run env HOME="$TEMPORARY_HOME" COLUMNS=300 GAIA_RATE_LIMITS_NOW="$NOW" \
    bash -c "printf '%s' \"\$PAYLOAD\" | bash '$STATUSLINE'"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  PLAIN_OUTPUT=$(sed "s/${ESCAPE_CHARACTER}\[[0-9;]*m//g" <<<"$output")
}

@test "a worktree session shows the main session's higher seven-day figure and the reader prints the window" {
  render "$MAIN" 62
  grep -qF "📅 62%" <<<"$PLAIN_OUTPUT" || { echo "session A: $PLAIN_OUTPUT"; return 1; }

  render "$WORKTREE" 35
  grep -qF "📅 62%" <<<"$PLAIN_OUTPUT" || { echo "session B did not show A's figure: $PLAIN_OUTPUT"; return 1; }
  grep -qF "📅 35%" <<<"$PLAIN_OUTPUT" && { echo "session B showed its own lower figure: $PLAIN_OUTPUT"; return 1; }

  cd "$WORKTREE"
  run env GAIA_RATE_LIMITS_NOW="$NOW" TZ=UTC bash "$CLI" read
  [ "$status" -eq 0 ] || { echo "reader status $status: $output"; return 1; }
  grep -qE '^seven_day 62% resets ' <<<"$output" || { echo "reader output: $output"; return 1; }
}
