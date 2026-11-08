#!/usr/bin/env bats

# Tests for the default left side of .gaia/statusline/gaia-statusline.sh
# (sourced sibling gaia-statusline-left.sh): project, branch with a linked-worktree
# marker, model and effort, and a 10-cell context bar colored from the shared
# threshold lib's bands. A user global statusLine.command still wins.
#
# The bar color is asserted on the ANSI code that immediately precedes the
# 10-cell bar (green 32, yellow 33, red 31), and the fire and skull markers on
# their glyphs.

setup() {
  STATUSLINE_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)
  SCRIPTS_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)
  SESSION_ID="0a1b2c3d-1111-4222-8333-444455556666"

  MAIN=$(mktemp -d -t gaia-left-main-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/scripts" "$MAIN/.gaia/local/protected"
  cp "$STATUSLINE_SOURCE"/*.sh "$MAIN/.gaia/statusline/"
  cp "$SCRIPTS_SOURCE/main-root-lib.sh" "$SCRIPTS_SOURCE/context-checkpoint-lib.sh" "$MAIN/.gaia/scripts/"
  echo x >"$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m init
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' >"$MAIN/.gaia/local/setup-state.json"
  WORKTREE="${MAIN}-wt"
  TEMPORARY_HOME=$(mktemp -d -t gaia-left-home-XXXXXX)
  ESCAPE_CHARACTER=$'\033'
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" "${MAIN}-wt" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# render_at <cwd> <used_tokens> <window>: the percentage is derived from the
# token count so the pinned used_tokens equals <used_tokens> exactly.
render_at() {
  local cwd="$1" tokens="$2" window="$3" json
  json=$(jq -n --arg current_directory "$cwd" --arg session_id "$SESSION_ID" --argjson tokens "$tokens" --argjson window "$window" \
    '{session_id: $session_id, workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Claude Opus"}, effort: {level: "xhigh"},
      context_window: {used_percentage: ($tokens / $window * 100), context_window_size: $window}}')
  PAYLOAD="$json" run env HOME="$TEMPORARY_HOME" COLUMNS=300 bash -c "printf '%s' \"\$PAYLOAD\" | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
}

# The color digit (1, 2 or 3 of 31/32/33) immediately before the 10-cell bar.
bar_color() {
  local bar_pattern="${ESCAPE_CHARACTER}\[01;3([123])m(▓|░){10}"
  [[ $output =~ $bar_pattern ]] || { echo "no 10-cell bar in: $output"; return 1; }
  printf '%s' "${BASH_REMATCH[1]}"
}

# expect_band <window> <tokens> <green|yellow|red> <none|fire|skull>
expect_band() {
  local window="$1" tokens="$2" want_color="$3" want_marker="$4" code got
  case "$want_color" in green) code=2 ;; yellow) code=3 ;; red) code=1 ;; esac
  render_at "$MAIN" "$tokens" "$window"
  [ "$status" -eq 0 ] || { echo "status $status"; return 1; }
  got=$(bar_color) || return 1
  [ "$got" = "$code" ] || { echo "window=$window tokens=$tokens: color digit $got, want $code ($want_color)"; return 1; }
  case "$want_marker" in
    none) { grep -qF "🔥" <<<"$output" || grep -qF "💀" <<<"$output"; } && { echo "window=$window tokens=$tokens: unexpected marker"; return 1; } ;;
    fire) grep -qF "🔥" <<<"$output" || { echo "window=$window tokens=$tokens: no fire marker"; return 1; } ;;
    skull) grep -qF "💀" <<<"$output" || { echo "window=$window tokens=$tokens: no skull marker"; return 1; } ;;
  esac
  return 0
}

@test "UAT-018: from a linked worktree the default left side names the main project, the marked branch, model and effort, and a 10-cell bar with a percent" {
  git -C "$MAIN" worktree add --quiet "$WORKTREE" -b feature
  render_at "$WORKTREE" 250000 1000000
  [ "$status" -eq 0 ]
  grep -qF "$(basename "$MAIN")" <<<"$output"
  grep -qF "🌳 feature" <<<"$output"
  grep -qF "Opus (XHigh)" <<<"$output"
  grep -qF " 25%" <<<"$output"
  bar_color >/dev/null
  # The worktree's own folder name must not be the project shown.
  grep -qF "$(basename "$WORKTREE")" <<<"$output" && return 1
  true
}

@test "the main checkout shows its branch with no worktree marker" {
  render_at "$MAIN" 250000 1000000
  [ "$status" -eq 0 ]
  grep -qF "main" <<<"$output"
  grep -qF "🌳" <<<"$output" && return 1
  true
}

@test "UAT-018: a user global statusLine.command replaces the default left side" {
  mkdir -p "$TEMPORARY_HOME/.claude"
  printf '{"statusLine":{"type":"command","command":"printf USERLEFT"}}' >"$TEMPORARY_HOME/.claude/settings.json"
  render_at "$MAIN" 250000 1000000
  [ "$status" -eq 0 ]
  grep -qF "USERLEFT" <<<"$output"
  grep -qF "$(basename "$MAIN")" <<<"$output" && return 1
  grep -qE "(▓|░){10}" <<<"$output" && return 1
  true
}

# user_left_with_choice <settings.json content|-> : a global statusLine.command
# that prints USERLEFT, plus the main checkout's opt-ins file (- writes none).
user_left_with_choice() {
  mkdir -p "$TEMPORARY_HOME/.claude"
  printf '{"statusLine":{"type":"command","command":"printf USERLEFT"}}' >"$TEMPORARY_HOME/.claude/settings.json"
  [ "$1" = "-" ] || printf '%s' "$1" >"$MAIN/.gaia/local/settings.json"
}

assert_gaia_left() {
  grep -qF "USERLEFT" <<<"$output" && { echo "user left side drawn: $output"; return 1; }
  grep -qF "$(basename "$MAIN")" <<<"$output" || { echo "no GAIA left side: $output"; return 1; }
  grep -qE "(▓|░){10}" <<<"$output" || { echo "no bar: $output"; return 1; }
}

assert_user_left() {
  grep -qF "USERLEFT" <<<"$output" || { echo "user left side missing: $output"; return 1; }
  grep -qE "(▓|░){10}" <<<"$output" && { echo "GAIA bar drawn: $output"; return 1; }
  true
}

@test "left choice gaia: statusline.left gaia draws GAIA's left side over a global statusLine.command" {
  user_left_with_choice '{"version":1,"statusline":{"left":"gaia"}}'
  render_at "$MAIN" 250000 1000000
  [ "$status" -eq 0 ]
  assert_gaia_left
}

@test "left choice gaia: a linked worktree reads the main checkout's choice" {
  user_left_with_choice '{"version":1,"statusline":{"left":"gaia"}}'
  git -C "$MAIN" worktree add --quiet "$WORKTREE" -b feature
  render_at "$WORKTREE" 250000 1000000
  [ "$status" -eq 0 ]
  assert_gaia_left
}

@test "left choice user: statusline.left user keeps the global statusLine.command" {
  user_left_with_choice '{"version":1,"statusline":{"left":"user"}}'
  render_at "$MAIN" 250000 1000000
  [ "$status" -eq 0 ]
  assert_user_left
}

@test "left choice missing: no opt-ins file keeps the global statusLine.command" {
  user_left_with_choice -
  render_at "$MAIN" 250000 1000000
  [ "$status" -eq 0 ]
  assert_user_left
}

@test "left choice missing: an opt-ins file with no statusline.left keeps the global statusLine.command" {
  user_left_with_choice '{"version":1}'
  render_at "$MAIN" 250000 1000000
  [ "$status" -eq 0 ]
  assert_user_left
}

@test "left choice malformed: a version-less file reads as missing" {
  user_left_with_choice '{"statusline":{"left":"gaia"}}'
  render_at "$MAIN" 250000 1000000
  [ "$status" -eq 0 ]
  assert_user_left
}

@test "left choice malformed: invalid JSON reads as missing" {
  user_left_with_choice '{"version":1,"statusline":{"left":"gaia"'
  render_at "$MAIN" 250000 1000000
  [ "$status" -eq 0 ]
  assert_user_left
}

@test "left choice malformed: an unknown left value reads as missing" {
  user_left_with_choice '{"version":1,"statusline":{"left":"GAIA"}}'
  render_at "$MAIN" 250000 1000000
  [ "$status" -eq 0 ]
  assert_user_left
}

@test "last resort: when the default left side cannot render, the bare label does" {
  rm "$MAIN/.gaia/statusline/gaia-statusline-left.sh"
  render_at "$MAIN" 250000 1000000
  [ "$status" -eq 0 ]
  grep -qF "Claude Code" <<<"$output"
}

@test "a payload with no context_window renders the left side without a bar" {
  PAYLOAD=$(jq -n --arg current_directory "$MAIN" '{workspace: {current_dir: $current_directory}, model: {display_name: "Claude Opus"}}') \
    run env HOME="$TEMPORARY_HOME" COLUMNS=300 bash -c "printf '%s' \"\$PAYLOAD\" | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  grep -qF "Opus" <<<"$output"
  grep -qE "(▓|░){10}" <<<"$output" && return 1
  true
}

# render_usage <rate_limits JSON, or - for no key>: a full payload with the given
# rate_limits value, printed with its ANSI escapes stripped into PLAIN_OUTPUT.
render_usage() {
  local rate_limits="$1" json
  json=$(jq -n --arg current_directory "$MAIN" \
    '{workspace: {current_dir: $current_directory}, model: {display_name: "Claude Opus"}, effort: {level: "xhigh"},
      context_window: {used_percentage: 21, context_window_size: 1000000}}')
  [ "$rate_limits" = "-" ] || json=$(jq --argjson rate_limits "$rate_limits" '. + {rate_limits: $rate_limits}' <<<"$json")
  PAYLOAD="$json" run env HOME="$TEMPORARY_HOME" COLUMNS=300 bash -c "printf '%s' \"\$PAYLOAD\" | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  PLAIN_OUTPUT=$(sed "s/${ESCAPE_CHARACTER}\[[0-9;]*m//g" <<<"$output")
}

# expect_usage_color <percentage> <31|32|33>: the ANSI color right before the
# 5-hour percentage.
expect_usage_color() {
  render_usage "{\"five_hour\":{\"used_percentage\":$1}}"
  [ "$status" -eq 0 ] || { echo "status $status"; return 1; }
  grep -qF "🕔 ${ESCAPE_CHARACTER}[01;$2m$1%" <<<"$output" || { echo "percentage $1: no color $2 in: $output"; return 1; }
}

@test "usage windows: both render after the context bar, rounded and divided like every other segment" {
  render_usage '{"five_hour":{"used_percentage":23.5},"seven_day":{"used_percentage":41.2}}'
  [ "$status" -eq 0 ]
  grep -qF "21% │ 🕔 24% │ 📅 41%" <<<"$PLAIN_OUTPUT"
}

@test "usage windows: only the 7-day window renders when the 5-hour window is absent" {
  render_usage '{"seven_day":{"used_percentage":41}}'
  [ "$status" -eq 0 ]
  grep -qF "21% │ 📅 41%" <<<"$PLAIN_OUTPUT"
  grep -qF "🕔" <<<"$PLAIN_OUTPUT" && return 1
  true
}

@test "usage windows: only the 5-hour window renders when the 7-day window is absent" {
  render_usage '{"five_hour":{"used_percentage":23}}'
  [ "$status" -eq 0 ]
  grep -qF "21% │ 🕔 23%" <<<"$PLAIN_OUTPUT"
  grep -qF "📅" <<<"$PLAIN_OUTPUT" && return 1
  true
}

@test "usage windows: a real 0% renders rather than reading as absent" {
  render_usage '{"five_hour":{"used_percentage":0}}'
  [ "$status" -eq 0 ]
  grep -qF "🕔 0%" <<<"$PLAIN_OUTPUT"
}

@test "usage windows: a payload with no rate_limits renders no usage segment and keeps the rest" {
  render_usage -
  [ "$status" -eq 0 ]
  grep -qF "Opus (XHigh)" <<<"$PLAIN_OUTPUT"
  grep -qF "21%" <<<"$PLAIN_OUTPUT"
  grep -qE "🕔|📅" <<<"$PLAIN_OUTPUT" && return 1
  true
}

@test "usage windows: wrong-typed values drop the window and never take the other fields down" {
  local malformed
  for malformed in '"soon"' '{"five_hour":"soon"}' '{"five_hour":{"used_percentage":"23"}}' '{"five_hour":{"used_percentage":-1}}'; do
    render_usage "$malformed"
    [ "$status" -eq 0 ] || { echo "$malformed: status $status"; return 1; }
    grep -qF "Opus (XHigh)" <<<"$PLAIN_OUTPUT" || { echo "$malformed: other fields lost: $PLAIN_OUTPUT"; return 1; }
    grep -qF "🕔" <<<"$PLAIN_OUTPUT" && { echo "$malformed: window rendered: $PLAIN_OUTPUT"; return 1; }
  done
  true
}

@test "usage windows: the color bands change at their edges" {
  expect_usage_color 74 32
  expect_usage_color 75 33
  expect_usage_color 89 33
  expect_usage_color 90 31
}

@test "usage windows: a red window shows the time until it resets, and a yellow one does not" {
  local now
  now=$(date +%s)
  # Each offset sits mid-minute, so a slow test run cannot cross a rounding edge.
  render_usage "{\"five_hour\":{\"used_percentage\":92,\"resets_at\":$((now + 3690))}}"
  grep -qF "🕔 92% (1h2m)" <<<"$PLAIN_OUTPUT" || { echo "hours: $PLAIN_OUTPUT"; return 1; }
  render_usage "{\"five_hour\":{\"used_percentage\":92,\"resets_at\":$((now + 690))}}"
  grep -qF "🕔 92% (12m)" <<<"$PLAIN_OUTPUT" || { echo "minutes: $PLAIN_OUTPUT"; return 1; }
  render_usage "{\"seven_day\":{\"used_percentage\":92,\"resets_at\":$((now + 187230))}}"
  grep -qF "📅 92% (2d4h)" <<<"$PLAIN_OUTPUT" || { echo "days: $PLAIN_OUTPUT"; return 1; }
  render_usage "{\"five_hour\":{\"used_percentage\":80,\"resets_at\":$((now + 3690))}}"
  grep -qF "(1h" <<<"$PLAIN_OUTPUT" && { echo "yellow countdown: $PLAIN_OUTPUT"; return 1; }
  true
}

@test "usage windows: a red window with a past or missing reset time shows no countdown" {
  local now
  now=$(date +%s)
  render_usage "{\"five_hour\":{\"used_percentage\":92,\"resets_at\":$((now - 60))}}"
  grep -qF "🕔 92%" <<<"$PLAIN_OUTPUT" || { echo "past: $PLAIN_OUTPUT"; return 1; }
  grep -qF "🕔 92% (" <<<"$PLAIN_OUTPUT" && { echo "past countdown: $PLAIN_OUTPUT"; return 1; }
  render_usage '{"five_hour":{"used_percentage":92}}'
  grep -qF "🕔 92%" <<<"$PLAIN_OUTPUT" || { echo "missing: $PLAIN_OUTPUT"; return 1; }
  grep -qF "🕔 92% (" <<<"$PLAIN_OUTPUT" && { echo "missing countdown: $PLAIN_OUTPUT"; return 1; }
  true
}

@test "UAT-022: 1M window band edges with no override" {
  expect_band 1000000 100000 green none
  expect_band 1000000 200000 green none
  expect_band 1000000 249999 green none
  expect_band 1000000 250000 yellow none
  expect_band 1000000 299999 yellow none
  expect_band 1000000 300000 red none
  expect_band 1000000 374999 red none
  expect_band 1000000 375000 red fire
  expect_band 1000000 449999 red fire
  expect_band 1000000 450000 red skull
}

@test "UAT-022: 200k window band edges with no override" {
  expect_band 200000 10000 green none
  expect_band 200000 59999 green none
  expect_band 200000 60000 yellow none
  expect_band 200000 99999 yellow none
  expect_band 200000 100000 red none
  expect_band 200000 124999 red none
  expect_band 200000 125000 red fire
  expect_band 200000 149999 red fire
  expect_band 200000 150000 red skull
}

@test "UAT-019: a lowered ask_tokens moves the red edge and leaves no yellow band" {
  printf '{"version":1,"context_checkpoint":{"ask_tokens":200000}}' >"$MAIN/.gaia/local/protected/checkpoint-override.json"
  expect_band 1000000 199999 green none
  expect_band 1000000 200000 red none
  expect_band 1000000 249999 red none
  expect_band 1000000 250000 red fire
  expect_band 1000000 300000 red skull
}

@test "UAT-019: an ask_tokens above the default reads as the default" {
  printf '{"version":1,"context_checkpoint":{"ask_tokens":600000}}' >"$MAIN/.gaia/local/protected/checkpoint-override.json"
  expect_band 1000000 250000 yellow none
  expect_band 1000000 300000 red none
}

@test "UAT-019: a non-integer ask_tokens reads as the default" {
  printf '{"version":1,"context_checkpoint":{"ask_tokens":"abc"}}' >"$MAIN/.gaia/local/protected/checkpoint-override.json"
  expect_band 1000000 250000 yellow none
  expect_band 1000000 300000 red none
}

@test "an override at the retired location leaves the band at the default" {
  local OLD_OVERRIDE="$MAIN/.gaia/local/checkpoint-override.json"
  printf '{"version":1,"context_checkpoint":{"ask_tokens":200000}}' >"$OLD_OVERRIDE"
  expect_band 1000000 250000 yellow none
  expect_band 1000000 300000 red none
}

@test "red state: the bar reads the lib, not a local constant (moving the lib default moves the red edge)" {
  # Control: with the shipped lib, 250000 on a 1M window is still yellow.
  expect_band 1000000 250000 yellow none
  # Change the lib default in the sandbox copy only; the bar must follow it.
  local library_file="$MAIN/.gaia/scripts/context-checkpoint-lib.sh"
  sed 's/^GAIA_CONTEXT_ASK_TOKENS_DEFAULT=.*/GAIA_CONTEXT_ASK_TOKENS_DEFAULT=280000/' "$library_file" >"$library_file.new"
  grep -q '^GAIA_CONTEXT_ASK_TOKENS_DEFAULT=280000$' "$library_file.new"
  mv "$library_file.new" "$library_file"
  expect_band 1000000 279999 yellow none
  expect_band 1000000 280000 red none
}
