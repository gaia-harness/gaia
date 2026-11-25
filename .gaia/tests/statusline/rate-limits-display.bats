#!/usr/bin/env bats
#
# Suite for how the statusline produces and displays the rate-limit reading:
# every render writes its payload's windows to its own session's file under the
# main checkout, and GAIA's left side draws the latest change across sessions.
# Renders run the real gaia-statusline.sh against a scratch git checkout with
# the clock pinned.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/statusline/rate-limits-display.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

NOW=1795440000
SESSION_A="0a1b2c3d-1111-4222-8333-444455556666"
SESSION_B="1b2c3d4e-2222-4333-8444-555566667777"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STATUSLINE="$REPO_ROOT/.gaia/statusline/gaia-statusline.sh"
  CLI="$REPO_ROOT/.gaia/scripts/rate-limits.sh"
  # shellcheck source=.gaia/tests/helpers/rate-limits-fixture.sh
  . "$REPO_ROOT/.gaia/tests/helpers/rate-limits-fixture.sh"
  ESCAPE_CHARACTER=$'\033'
  FIVE_HOUR_RESETS_AT=$((NOW + 3690))
  SEVEN_DAY_RESETS_AT=$((NOW + 187230))
  MAIN="$BATS_TEST_TMPDIR/main"
  TEMPORARY_HOME="$BATS_TEST_TMPDIR/home"
  FOLDER="$MAIN/.gaia/local/cache/shared/rate-limits"
  FILE="$FOLDER/$SESSION_A.json"
  OTHER_FILE="$FOLDER/$SESSION_B.json"
  mkdir -p "$MAIN/.gaia/local" "$TEMPORARY_HOME"
  git -C "$MAIN" init -q --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  echo x >"$MAIN/README.md"
  git -C "$MAIN" add README.md
  git -C "$MAIN" commit -q -m init
  printf '{"version":1,"statusline":{"left":"gaia"}}' >"$MAIN/.gaia/local/settings.json"
  export TZ=UTC
}

teardown() {
  chmod -R u+rwx "$MAIN/.gaia" 2>/dev/null || true
  return 0
}

# render <cwd> <rate_limits JSON, or - for no key> [<now>] [<session id>]: one
# session's render (session A unless named); PLAIN_OUTPUT is the output with
# its ANSI escapes stripped.
render() {
  local cwd="$1" rate_limits="$2" now="${3:-$NOW}" session_id="${4:-$SESSION_A}" json
  json=$(jq -n --arg current_directory "$cwd" --arg session_id "$session_id" \
    '{session_id: $session_id, workspace: {current_dir: $current_directory}, model: {display_name: "Claude Opus"}, effort: {level: "xhigh"},
      context_window: {used_percentage: 21, context_window_size: 1000000}}')
  [ "$rate_limits" = "-" ] || json=$(jq --argjson rate_limits "$rate_limits" '. + {rate_limits: $rate_limits}' <<<"$json")
  PAYLOAD="$json" run env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CONFIG_DIR HOME="$TEMPORARY_HOME" COLUMNS=300 GAIA_RATE_LIMITS_NOW="$now" \
    bash -c "printf '%s' \"\$PAYLOAD\" | bash '$STATUSLINE'"
  PLAIN_OUTPUT=$(sed "s/${ESCAPE_CHARACTER}\[[0-9;]*m//g" <<<"$output")
}

# seed_file <name> <percentage> <resets_at> [<name> <percentage> <resets_at> ...]:
# session A's valid stored file, changed and confirmed at NOW.
seed_file() {
  rate_limits_seed_session "$MAIN" "$SESSION_A" "$NOW" true "$@"
}

# stored <jq filter>: the filter applied to session A's stored file.
stored() {
  jq -c "$1" "$FILE"
}

# expect_color <icon> <percentage> <digit>: the ANSI color digit (1 red, 2 green,
# 3 yellow) right before the figure.
expect_color() {
  local icon="$1" percentage="$2" digit="$3" want
  want="$icon ${ESCAPE_CHARACTER}[01;3${digit}m${percentage}%"
  grep -qF "$want" <<<"$output" || { echo "$icon $percentage: no color $digit in: $output"; return 1; }
}

@test "a render writes only its own session's file and a new figure replaces the stored one either way" {
  local other_before
  rate_limits_seed_session "$MAIN" "$SESSION_B" "$NOW" true five_hour 55 "$FIVE_HOUR_RESETS_AT"
  other_before=$(cat "$OTHER_FILE")

  seed_file five_hour 99 "$FIVE_HOUR_RESETS_AT"
  render "$MAIN" "{\"five_hour\":{\"used_percentage\":3,\"resets_at\":$FIVE_HOUR_RESETS_AT}}" "$((NOW + 60))"
  [ "$(stored '.windows.five_hour | [.used_percentage, .resets_at, .changed_at, .confirmed]')" = "[3,$FIVE_HOUR_RESETS_AT,$((NOW + 60)),true]" ] || { echo "lower figure: $(cat "$FILE")"; return 1; }
  [ "$(stored '.windows.five_hour.history[-1].used_percentage')" = "3" ] || { echo "history: $(cat "$FILE")"; return 1; }

  seed_file five_hour 80 "$FIVE_HOUR_RESETS_AT"
  render "$MAIN" "{\"five_hour\":{\"used_percentage\":45,\"resets_at\":$((FIVE_HOUR_RESETS_AT + 30))}}" "$((NOW + 60))"
  [ "$(stored '.windows.five_hour | [.used_percentage, .resets_at]')" = "[45,$((FIVE_HOUR_RESETS_AT + 30))]" ] || { echo "new reset time: $(cat "$FILE")"; return 1; }

  seed_file seven_day 60 "$SEVEN_DAY_RESETS_AT"
  render "$MAIN" "{\"seven_day\":{\"used_percentage\":70}}" "$((NOW + 60))"
  [ "$(stored '.windows.seven_day | [.used_percentage, .resets_at, .confirmed]')" = "[70,$SEVEN_DAY_RESETS_AT,true]" ] || { echo "no reset time: $(cat "$FILE")"; return 1; }

  [ "$(cat "$OTHER_FILE")" = "$other_before" ] || { echo "other session's file changed: $(cat "$OTHER_FILE")"; return 1; }
  [ "$(find "$FOLDER" -type f | wc -l | tr -d ' ')" = "2" ] || { echo "files: $(find "$FOLDER" -type f)"; return 1; }
  true
}

@test "a window missing from the payload stays missing and keeps the stored reading" {
  render "$MAIN" "{\"seven_day\":{\"used_percentage\":41,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  [ "$(stored '.windows | keys')" = '["seven_day"]' ] || { echo "keys: $(stored '.windows | keys')"; return 1; }
  grep -qF "📅 41%" <<<"$PLAIN_OUTPUT" || { echo "no calendar segment: $PLAIN_OUTPUT"; return 1; }
  grep -qF "🕔" <<<"$PLAIN_OUTPUT" && { echo "clock segment drawn: $PLAIN_OUTPUT"; return 1; }

  rm -f "$FILE"
  seed_file five_hour 40 "$FIVE_HOUR_RESETS_AT"
  render "$MAIN" "{\"seven_day\":{\"used_percentage\":41,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  [ "$(stored '.windows.five_hour.used_percentage')" = "40" ] || { echo "five_hour lost: $(cat "$FILE")"; return 1; }
  expect_color "🕔" 40 2
  true
}

@test "an expired window renders reset in the statusline and the reader" {
  local reset_time=$((NOW + 100))
  seed_file five_hour 92 "$reset_time"
  render "$MAIN" - "$((reset_time + 1))"
  grep -qF "🕔 ${ESCAPE_CHARACTER}[01;32mreset${ESCAPE_CHARACTER}[00m" <<<"$output" || { echo "no green reset: $output"; return 1; }
  grep -qE "🕔 reset *(\(|[0-9])" <<<"$PLAIN_OUTPUT" && { echo "percentage or countdown: $PLAIN_OUTPUT"; return 1; }
  run env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CONFIG_DIR HOME="$TEMPORARY_HOME" GAIA_RATE_LIMITS_NOW="$((reset_time + 1))" bash -c "cd '$MAIN' && bash '$CLI' read"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "five_hour reset" ] || { echo "reader: $output"; return 1; }
}

@test "an idle session's left side follows the session whose figure changed most recently" {
  rate_limits_seed_session "$MAIN" "$SESSION_A" "$((NOW - 1000))" true seven_day 60 "$SEVEN_DAY_RESETS_AT"
  rate_limits_seed_session "$MAIN" "$SESSION_B" "$((NOW - 10))" true seven_day 22 "$SEVEN_DAY_RESETS_AT"
  render "$MAIN" "{\"seven_day\":{\"used_percentage\":60,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  grep -qF "📅 22%" <<<"$PLAIN_OUTPUT" || { echo "idle session did not follow: $PLAIN_OUTPUT"; return 1; }
  [ "$(stored '.windows.seven_day.used_percentage')" = "60" ] || { echo "own file changed: $(cat "$FILE")"; return 1; }

  printf '{' >"$OTHER_FILE"
  render "$MAIN" "{\"seven_day\":{\"used_percentage\":60,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  grep -qF "📅 60%" <<<"$PLAIN_OUTPUT" || { echo "unparseable file not skipped: $PLAIN_OUTPUT"; return 1; }
  true
}

@test "usage colors and countdowns follow the bands the library defines" {
  local percentage digit
  for percentage in 74:2 75:3 89:3 90:1; do
    digit="${percentage#*:}"
    percentage="${percentage%%:*}"
    rm -rf "$FOLDER"
    render "$MAIN" "{\"five_hour\":{\"used_percentage\":$percentage,\"resets_at\":$FIVE_HOUR_RESETS_AT},\"seven_day\":{\"used_percentage\":$percentage,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
    expect_color "🕔" "$percentage" "$digit"
    expect_color "📅" "$percentage" "$digit"
    if [ "$percentage" -ge 75 ]; then
      grep -qF "🕔 $percentage% (1h2m)" <<<"$PLAIN_OUTPUT" || { echo "5h countdown at $percentage: $PLAIN_OUTPUT"; return 1; }
    else
      grep -qF "🕔 $percentage% (" <<<"$PLAIN_OUTPUT" && { echo "5h countdown at $percentage: $PLAIN_OUTPUT"; return 1; }
    fi
    if [ "$percentage" -ge 90 ]; then
      grep -qF "📅 $percentage% (2d4h)" <<<"$PLAIN_OUTPUT" || { echo "7d countdown at $percentage: $PLAIN_OUTPUT"; return 1; }
    else
      grep -qF "📅 $percentage% (" <<<"$PLAIN_OUTPUT" && { echo "7d countdown at $percentage: $PLAIN_OUTPUT"; return 1; }
    fi
  done
  grep -rqE "GAIA_USAGE_(YELLOW|RED)_PERCENTAGE" "$REPO_ROOT/.gaia/statusline" && { echo "a second copy of the bands"; return 1; }
  true
}

@test "a payload window with no reset time is shown, and shown from another session's confirmed entry when one exists" {
  render "$MAIN" '{"five_hour":{"used_percentage":40}}'
  grep -qF "🕔 40%" <<<"$PLAIN_OUTPUT" || { echo "not shown: $PLAIN_OUTPUT"; return 1; }
  grep -qF "🕔 40% (" <<<"$PLAIN_OUTPUT" && { echo "countdown: $PLAIN_OUTPUT"; return 1; }
  if [ -f "$FILE" ]; then
    [ "$(stored '.windows | has("five_hour")')" = "false" ] || { echo "written: $(cat "$FILE")"; return 1; }
  fi

  rate_limits_seed_session "$MAIN" "$SESSION_B" "$NOW" true five_hour 50 "$FIVE_HOUR_RESETS_AT"
  render "$MAIN" '{"five_hour":{"used_percentage":40}}'
  grep -qF "🕔 50%" <<<"$PLAIN_OUTPUT" || { echo "other session's figure lost: $PLAIN_OUTPUT"; return 1; }
  true
}

@test "every render writes the reading whatever draws the left side" {
  printf '{"version":1,"statusline":{"left":"user"}}' >"$MAIN/.gaia/local/settings.json"
  mkdir -p "$TEMPORARY_HOME/.claude"
  printf '{"statusLine":{"type":"command","command":"printf USERLEFT"}}' >"$TEMPORARY_HOME/.claude/settings.json"
  render "$MAIN" "{\"seven_day\":{\"used_percentage\":85,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  grep -qF "USERLEFT" <<<"$PLAIN_OUTPUT" || { echo "user command not drawn: $PLAIN_OUTPUT"; return 1; }
  [ "$(stored '.windows.seven_day.used_percentage')" = "85" ] || { echo "not written: $(cat "$FILE" 2>&1)"; return 1; }
  true
}

@test "a failed write shows the payload figure and leaves no temporary file" {
  [ "$(id -u)" -ne 0 ] || skip "a read-only directory does not stop root"
  seed_file seven_day 80 "$SEVEN_DAY_RESETS_AT"
  local before
  before=$(cat "$FILE")
  chmod 555 "$FOLDER"
  render "$MAIN" "{\"seven_day\":{\"used_percentage\":90,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  chmod 755 "$FOLDER"
  expect_color "📅" 90 1
  [ "$(cat "$FILE")" = "$before" ] || { echo "file changed: $(cat "$FILE")"; return 1; }
  local leftover
  leftover=$(find "$FOLDER" -name '*.tmp.*')
  [ -z "$leftover" ] || { echo "temporary file: $leftover"; return 1; }
  grep -qi "rate-limits" <<<"$PLAIN_OUTPUT" && { echo "noise: $PLAIN_OUTPUT"; return 1; }
  true
}

# read_as_session_a <now>: the reader as session A, clock pinned.
read_as_session_a() {
  run env -u CLAUDE_CONFIG_DIR HOME="$TEMPORARY_HOME" CLAUDE_CODE_SESSION_ID="$SESSION_A" GAIA_RATE_LIMITS_NOW="$1" \
    bash -c "cd '$MAIN' && bash '$CLI' read"
}

# The foreign reading is a copy of a real file that an ended session on another
# account left in a shared cache; the own reading is an Ultra account's, which
# reports no five-hour window.
@test "the reader shows only the session's own windows once it has a reading, and falls back across sessions before" {
  local now=1795591624
  mkdir -p "$FOLDER"
  printf '%s\n' '{"version":2,"windows":{"five_hour":{"used_percentage":75,"resets_at":1795600800,"changed_at":1795588275,"confirmed":true,"history":[{"used_percentage":74,"changed_at":1795588243},{"used_percentage":75,"changed_at":1795588275}]},"seven_day":{"used_percentage":58,"resets_at":1795946400,"changed_at":1795588243,"confirmed":false,"history":[{"used_percentage":58,"changed_at":1795588243}]}}}' >"$OTHER_FILE"

  read_as_session_a "$now"
  [ "$status" -eq 0 ] || return 1
  grep -qF "five_hour 75% warning" <<<"$output" || { echo "no own reading, fallback lost: $output"; return 1; }

  printf '%s\n' '{"version":2,"windows":{"seven_day":{"used_percentage":57,"resets_at":1796054400,"changed_at":1795591592,"confirmed":false,"history":[{"used_percentage":57,"changed_at":1795591592}]}}}' >"$FILE"
  read_as_session_a "$now"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "seven_day 57% resets Mon 16:00 (in 5d8h) projected unknown changed 0m ago unconfirmed" ] || { echo "own reading: $output"; return 1; }

  rate_limits_seed_session "$MAIN" "$SESSION_A" "$now" true five_hour 20 1795600800
  read_as_session_a "$now"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "five_hour 20% resets 10:00 (in 2h33m) projected unknown changed 0m ago" ] || { echo "own five_hour: $output"; return 1; }
}
