#!/usr/bin/env bats
#
# Write-path test: a statusline render from a linked worktree stores its
# session's rate-limit reading under the main checkout's per-session folder,
# never under the worktree. Which figure a session displays is owned by the
# rate-limits-display suite and the library suite.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/statusline/shared-rate-limit-reading.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

NOW=1795440000
SESSION_ID="0a1b2c3d-1111-4222-8333-444455556666"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STATUSLINE="$REPO_ROOT/.gaia/statusline/gaia-statusline.sh"
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

@test "a render in a linked worktree writes its session file under the main checkout and nothing under the worktree" {
  local json reading
  json=$(jq -n --arg current_directory "$WORKTREE" --arg session_id "$SESSION_ID" --argjson resets_at "$SEVEN_DAY_RESETS_AT" \
    '{session_id: $session_id, workspace: {current_dir: $current_directory}, model: {display_name: "Claude Opus"}, effort: {level: "xhigh"},
      context_window: {used_percentage: 21, context_window_size: 1000000},
      rate_limits: {seven_day: {used_percentage: 62, resets_at: $resets_at}}}')
  PAYLOAD="$json" run env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CONFIG_DIR HOME="$TEMPORARY_HOME" COLUMNS=300 GAIA_RATE_LIMITS_NOW="$NOW" \
    bash -c "printf '%s' \"\$PAYLOAD\" | bash '$STATUSLINE'"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }

  reading="$MAIN/.gaia/local/cache/shared/rate-limits/$SESSION_ID.json"
  [ -f "$reading" ] || { echo "no reading at $reading"; return 1; }
  [ "$(jq -r '.windows.seven_day.used_percentage' "$reading")" = "62" ] || { echo "reading: $(cat "$reading")"; return 1; }
  local stray
  stray=$(find "$WORKTREE" -path '*rate-limits*' -not -path '*/.git/*')
  [ -z "$stray" ] || { echo "created in worktree: $stray"; return 1; }
  true
}
