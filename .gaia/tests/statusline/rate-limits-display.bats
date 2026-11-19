#!/usr/bin/env bats
#
# Suite for how the statusline produces and displays the shared rate-limit
# reading: every render merges its payload into the main checkout's shared file
# and GAIA's left side draws from the merged result. Renders run the real
# gaia-statusline.sh against a scratch git checkout with the clock pinned.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/statusline/rate-limits-display.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

NOW=1795440000

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
  WORKTREE="$BATS_TEST_TMPDIR/worktree"
  TEMPORARY_HOME="$BATS_TEST_TMPDIR/home"
  FILE="$MAIN/.gaia/local/cache/shared/rate-limits.json"
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

# render <cwd> <rate_limits JSON, or - for no key> [<now>]: one session's
# render; PLAIN_OUTPUT is the output with its ANSI escapes stripped.
render() {
  local cwd="$1" rate_limits="$2" now="${3:-$NOW}" json
  json=$(jq -n --arg current_directory "$cwd" \
    '{workspace: {current_dir: $current_directory}, model: {display_name: "Claude Opus"}, effort: {level: "xhigh"},
      context_window: {used_percentage: 21, context_window_size: 1000000}}')
  [ "$rate_limits" = "-" ] || json=$(jq --argjson rate_limits "$rate_limits" '. + {rate_limits: $rate_limits}' <<<"$json")
  PAYLOAD="$json" run env HOME="$TEMPORARY_HOME" COLUMNS=300 GAIA_RATE_LIMITS_NOW="$now" \
    bash -c "printf '%s' \"\$PAYLOAD\" | bash '$STATUSLINE'"
  PLAIN_OUTPUT=$(sed "s/${ESCAPE_CHARACTER}\[[0-9;]*m//g" <<<"$output")
}

# seed_file <name> <percentage> <resets_at> [<name> <percentage> <resets_at> ...]:
# a valid stored file, observed at NOW.
seed_file() {
  rate_limits_seed_file "$FILE" "$NOW" "$@"
}

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
  run env GAIA_RATE_LIMITS_NOW="$((reset_time + 1))" bash -c "cd '$MAIN' && bash '$CLI' read"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "five_hour reset" ] || { echo "reader: $output"; return 1; }
}

@test "the left side displays from the merged file and repairs an unparseable one" {
  seed_file seven_day 90 "$SEVEN_DAY_RESETS_AT"
  render "$MAIN" "{\"seven_day\":{\"used_percentage\":80,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  expect_color "📅" 90 1
  [ "$(stored '.windows.seven_day.used_percentage')" = "90" ] || return 1

  printf '{not json' >"$FILE"
  render "$MAIN" "{\"seven_day\":{\"used_percentage\":80,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  expect_color "📅" 80 3
  [ "$(stored '.windows.seven_day.used_percentage')" = "80" ] || { echo "not repaired: $(cat "$FILE")"; return 1; }
  true
}

@test "two renders in the same second leave valid JSON and the next render restores the higher value" {
  local payload_high="{\"seven_day\":{\"used_percentage\":80,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  local payload_low="{\"seven_day\":{\"used_percentage\":70,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  render "$MAIN" "$payload_high" &
  render "$MAIN" "$payload_low" &
  wait
  jq -e . "$FILE" >/dev/null || { echo "not JSON: $(cat "$FILE")"; return 1; }
  case "$(stored '.windows.seven_day.used_percentage')" in
    80 | 70) ;;
    *) echo "value: $(stored '.windows.seven_day.used_percentage')"; return 1 ;;
  esac
  render "$MAIN" "$payload_high"
  [ "$(stored '.windows.seven_day.used_percentage')" = "80" ] || { echo "not restored: $(cat "$FILE")"; return 1; }
  true
}

@test "a render in a linked worktree writes the main checkout reading" {
  git -C "$MAIN" worktree add -q "$WORKTREE" -b linked
  render "$WORKTREE" "{\"seven_day\":{\"used_percentage\":70,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  [ "$(stored '.windows.seven_day.used_percentage')" = "70" ] || { echo "main file: $(cat "$FILE" 2>&1)"; return 1; }
  local stray
  stray=$(find "$WORKTREE" -name 'rate-limits.json*' -not -path '*/.git/*')
  [ -z "$stray" ] || { echo "created in worktree: $stray"; return 1; }
  true
}

@test "any window name and producer is stored and read, only the 5-hour and 7-day windows are drawn, and producer never wins a merge" {
  run env GAIA_RATE_LIMITS_NOW="$NOW" bash -c "cd '$MAIN' && bash '$CLI' write '{\"producer\":\"mod\",\"windows\":{\"spend_limit\":{\"used_percentage\":30,\"resets_at\":$SEVEN_DAY_RESETS_AT}}}'"
  [ "$status" -eq 0 ] || { echo "write: $output"; return 1; }
  [ "$(stored '.windows.spend_limit.history[0].producer')" = '"mod"' ] || { echo "history: $(cat "$FILE")"; return 1; }
  run env GAIA_RATE_LIMITS_NOW="$NOW" bash -c "cd '$MAIN' && bash '$CLI' read"
  grep -q "^spend_limit 30%" <<<"$output" || { echo "reader: $output"; return 1; }
  render "$MAIN" -
  grep -qE "🕔|📅|spend" <<<"$PLAIN_OUTPUT" && { echo "drew a window: $PLAIN_OUTPUT"; return 1; }

  rm -f "$FILE"
  render "$MAIN" "{\"seven_day\":{\"used_percentage\":80,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  run env GAIA_RATE_LIMITS_NOW="$NOW" bash -c "cd '$MAIN' && bash '$CLI' write '{\"producer\":\"mod\",\"windows\":{\"seven_day\":{\"used_percentage\":70,\"resets_at\":$SEVEN_DAY_RESETS_AT}}}'"
  [ "$(stored '.windows.seven_day.used_percentage')" = "80" ] || { echo "producer won: $(cat "$FILE")"; return 1; }
  true
}

@test "usage colors and countdowns follow the bands the library defines" {
  local percentage digit
  for percentage in 74:2 75:3 89:3 90:1; do
    digit="${percentage#*:}"
    percentage="${percentage%%:*}"
    rm -f "$FILE"
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

@test "a payload window with no reset time is shown and never written" {
  render "$MAIN" '{"five_hour":{"used_percentage":40}}'
  grep -qF "🕔 40%" <<<"$PLAIN_OUTPUT" || { echo "not shown: $PLAIN_OUTPUT"; return 1; }
  grep -qF "🕔 40% (" <<<"$PLAIN_OUTPUT" && { echo "countdown: $PLAIN_OUTPUT"; return 1; }
  if [ -f "$FILE" ]; then
    [ "$(stored '.windows | has("five_hour")')" = "false" ] || { echo "written: $(cat "$FILE")"; return 1; }
  fi

  seed_file five_hour 50 "$FIVE_HOUR_RESETS_AT"
  render "$MAIN" '{"five_hour":{"used_percentage":40}}'
  grep -qF "🕔 50%" <<<"$PLAIN_OUTPUT" || { echo "file figure lost: $PLAIN_OUTPUT"; return 1; }
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

@test "a failed write shows no figure below the payload and leaves no temporary file" {
  [ "$(id -u)" -ne 0 ] || skip "a read-only directory does not stop root"
  seed_file seven_day 80 "$SEVEN_DAY_RESETS_AT"
  local before
  before=$(cat "$FILE")
  chmod 555 "${FILE%/*}"
  render "$MAIN" "{\"seven_day\":{\"used_percentage\":90,\"resets_at\":$SEVEN_DAY_RESETS_AT}}"
  chmod 755 "${FILE%/*}"
  expect_color "📅" 90 1
  [ "$(cat "$FILE")" = "$before" ] || { echo "file changed: $(cat "$FILE")"; return 1; }
  local leftover
  leftover=$(find "${FILE%/*}" -name 'rate-limits.json.tmp.*')
  [ -z "$leftover" ] || { echo "temporary file: $leftover"; return 1; }
  grep -qi "rate-limits" <<<"$PLAIN_OUTPUT" && { echo "noise: $PLAIN_OUTPUT"; return 1; }
  true
}
