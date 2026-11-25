#!/usr/bin/env bats
#
# Suite for .gaia/scripts/rate-limits.sh and the library behind it: the
# per-session writer rules, history, validation, the latest-change choice, the
# bands and the reader's lines, driven through the CLI in a scratch git
# checkout with the clock and TZ pinned, and through the real statusline and
# dispatch hook where a case names them.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/rate-limits.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# Monday 2026-11-23 00:00 UTC; every reader case runs under TZ=UTC.
MONDAY=1795392000
HOOK_SESSION=0b9c2d4e-1f3a-4b5c-8d7e-9f0a1b2c3d4e
SESSION_A=aaaaaaaa-1111-4111-8111-111111111111
SESSION_B=bbbbbbbb-2222-4222-8222-222222222222
SESSION_C=cccccccc-3333-4333-8333-333333333333
SESSION_D=dddddddd-4444-4444-8444-444444444444
SESSION_E=eeeeeeee-5555-4555-8555-555555555555

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI="$REPO_ROOT/.gaia/scripts/rate-limits.sh"
  # shellcheck source=.gaia/tests/helpers/rate-limits-fixture.sh
  . "$REPO_ROOT/.gaia/tests/helpers/rate-limits-fixture.sh"
  MAIN="$BATS_TEST_TMPDIR/main"
  mkdir -p "$MAIN" "$BATS_TEST_TMPDIR/home"
  git -C "$MAIN" init -q
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  FOLDER="$MAIN/.gaia/local/cache/shared/rate-limits"
  MARKER="$MAIN/.gaia/local/cache/rate-limit-checkpoint/$HOOK_SESSION.json"
  # No case may read the developer's real profile or session.
  unset CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR
  export HOME="$BATS_TEST_TMPDIR/home" TZ=UTC
}

# rate_limits <now> <verb> [<argument>...]: the CLI as a session in MAIN runs it.
rate_limits() {
  local now="$1"
  shift
  (cd "$MAIN" && GAIA_RATE_LIMITS_NOW="$now" bash "$CLI" "$@")
}

# stored <session-id> <jq-program>: a query over that session's reading file.
stored() {
  jq -c "$2" "$FOLDER/$1.json"
}

# put_reading <session-id> <file-text>: the session's file, byte for byte.
put_reading() {
  mkdir -p "$FOLDER"
  printf '%s\n' "$2" >"$FOLDER/$1.json"
}

# reading_json <name> <percentage> <resets_at> <changed_at> <history-json> [confirmed]
reading_json() {
  printf '{"version":2,"windows":{"%s":{"used_percentage":%s,"resets_at":%s,"changed_at":%s,"confirmed":%s,"history":%s}}}' \
    "$1" "$2" "$3" "$4" "${6:-true}" "$5"
}

# expect_reader <label> <now> <first-line-glob>: `read` prints a first line matching the glob.
expect_reader() {
  run rate_limits "$2" read
  [ "$status" -eq 0 ] || { echo "case $1: status $status"; return 1; }
  # shellcheck disable=SC2254 # each expected line is a glob: * stands for the parts a case does not pin
  case ${lines[0]:-} in
    $3) ;;
    *) echo "case $1: got '$output', want '$3'"; return 1 ;;
  esac
}

# prepare_render: the GAIA left side for every render in MAIN.
prepare_render() {
  mkdir -p "$MAIN/.gaia/local"
  printf '{"version":1,"statusline":{"left":"gaia"}}' >"$MAIN/.gaia/local/settings.json"
}

# render <now> <session-id> <rate_limits-json>: one real statusline render in
# MAIN; PLAIN_OUTPUT is its output without ANSI escapes.
render() {
  local now="$1" payload escape=$'\033'
  payload=$(jq -nc --arg current_directory "$MAIN" --arg session_id "$2" --argjson rate_limits "$3" \
    '{session_id: $session_id, workspace: {current_dir: $current_directory}, model: {display_name: "Claude Opus"},
      effort: {level: "xhigh"}, context_window: {used_percentage: 21, context_window_size: 1000000},
      rate_limits: $rate_limits}')
  PAYLOAD="$payload" run env COLUMNS=300 GAIA_RATE_LIMITS_NOW="$now" \
    bash -c "printf '%s' \"\$PAYLOAD\" | bash '$REPO_ROOT/.gaia/statusline/gaia-statusline.sh'"
  PLAIN_OUTPUT=$(sed "s/${escape}\[[0-9;]*m//g" <<<"$output")
}

# dispatch_hook <now> [<session-id>]: the real dispatch hook as a main session
# in MAIN. The marker persists between calls, as it does in a session.
dispatch_hook() {
  local now="$1" payload
  payload=$(jq -nc --arg cwd "$MAIN" --arg session_id "${2:-$HOOK_SESSION}" \
    '{hook_event_name: "PreToolUse", session_id: $session_id, cwd: $cwd, tool_name: "Agent", tool_input: {}}')
  run --separate-stderr env GAIA_RATE_LIMITS_NOW="$now" /bin/bash "$REPO_ROOT/.claude/hooks/rate-limit-checkpoint-inject.sh" <<<"$payload"
}

# writer_records <now> <session-id> <input-json>: the library writer's display
# records on stdout, then its return code as `rc=<n>`; its stderr is dropped.
writer_records() {
  GAIA_RATE_LIMITS_NOW="$1" bash -c '
    . "$1/.gaia/scripts/rate-limits-lib.sh"
    gaia_rate_limits_write "$2" "$3" "$4" "$5" 2>/dev/null
    printf "rc=%s\n" "$?"
  ' _ "$REPO_ROOT" "$MAIN" "$1" "$2" "$3"
}

@test "a same-window reading replaces the stored figure in either direction and touches only the session's own file" {
  local now=1795440000 reset=1795449600 other_before legacy
  legacy="$FOLDER.json"
  mkdir -p "${legacy%/*}"
  printf '%s\n' '{"version":1,"windows":{"seven_day":{"used_percentage":60}}}' >"$legacy"
  rate_limits_seed_session "$MAIN" "$SESSION_B" $((now - 600)) true five_hour 70 "$reset"
  other_before="$(cat "$FOLDER/$SESSION_B.json")"

  run rate_limits "$now" write "$SESSION_A" "{\"windows\":{\"five_hour\":{\"used_percentage\":99,\"resets_at\":$reset}}}"
  [ "$status" -eq 0 ] || return 1
  run rate_limits $((now + 60)) write "$SESSION_A" "{\"windows\":{\"five_hour\":{\"used_percentage\":3,\"resets_at\":$reset}}}"
  [ "$status" -eq 0 ] || return 1
  [ "$(stored "$SESSION_A" '.windows.five_hour | [.used_percentage, .changed_at, .confirmed, .history[-1].used_percentage]')" = "[3,$((now + 60)),true,3]" ] || return 1

  # A rise inside the slack stores the incoming reset time.
  run rate_limits $((now + 120)) write "$SESSION_A" "{\"windows\":{\"five_hour\":{\"used_percentage\":45,\"resets_at\":$((reset + 30))}}}"
  [ "$status" -eq 0 ] || return 1
  [ "$(stored "$SESSION_A" '.windows.five_hour | [.used_percentage, .resets_at]')" = "[45,$((reset + 30))]" ] || return 1

  # No reset time: stored against the stored reset, and nothing when none is stored.
  rate_limits_seed_session "$MAIN" "$SESSION_C" $((now - 600)) true seven_day 60 "$reset"
  run rate_limits "$now" write "$SESSION_C" '{"windows":{"seven_day":{"used_percentage":70}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored "$SESSION_C" '.windows.seven_day | [.used_percentage, .resets_at, .confirmed]')" = "[70,$reset,true]" ] || return 1
  run rate_limits "$now" write "$SESSION_A" '{"windows":{"seven_day":{"used_percentage":30}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored "$SESSION_A" '.windows | keys')" = '["five_hour"]' ] || return 1

  [ "$(cat "$FOLDER/$SESSION_B.json")" = "$other_before" ] || return 1
  [ "$(cat "$legacy")" = '{"version":1,"windows":{"seven_day":{"used_percentage":60}}}' ] || return 1
  expect_reader "legacy file beside the folder" $((now + 180)) "five_hour 45% resets *"
}

@test "a reset time past the slack replaces the window and its history, earlier or later" {
  local now=1795440000 reset=1795740000 label offset history
  history='[{"used_percentage":20,"changed_at":1795400000},{"used_percentage":30,"changed_at":1795410000},{"used_percentage":40,"changed_at":1795420000},{"used_percentage":50,"changed_at":1795430000},{"used_percentage":60,"changed_at":1795435000}]'
  while IFS='|' read -r label offset; do
    [ -n "$label" ] || continue
    put_reading "$SESSION_A" "$(reading_json seven_day 60 "$reset" 1795435000 "$history")"
    run rate_limits "$now" write "$SESSION_A" "{\"windows\":{\"seven_day\":{\"used_percentage\":10,\"resets_at\":$((reset + offset))}}}"
    [ "$status" -eq 0 ] || { echo "case $label: status $status"; return 1; }
    [ "$(stored "$SESSION_A" '.windows.seven_day | [.used_percentage, .resets_at, .confirmed, .changed_at, (.history | length)]')" = "[10,$((reset + offset)),true,$now,1]" ] \
      || { echo "case $label: $(cat "$FOLDER/$SESSION_A.json")"; return 1; }
  done <<'EOF'
two days earlier|-172800
two days later|172800
601 seconds later|601
EOF
}

@test "a changed figure appends one history entry and history keeps the newest 48" {
  local now=1795440000 resets_at=1795449600

  put_reading "$SESSION_A" "$(reading_json five_hour 40 "$resets_at" $((now - 300)) '[{"used_percentage":40,"changed_at":1795439700}]')"
  run rate_limits "$now" write "$SESSION_A" '{"windows":{"five_hour":{"used_percentage":40,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored "$SESSION_A" '.windows.five_hour.history | length')" = "1" ] || return 1

  run rate_limits "$now" write "$SESSION_A" '{"windows":{"five_hour":{"used_percentage":42,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored "$SESSION_A" '.windows.five_hour.history')" = '[{"used_percentage":40,"changed_at":1795439700},{"used_percentage":42,"changed_at":1795440000}]' ] || return 1

  put_reading "$SESSION_A" "$(jq -nc --argjson now "$now" --argjson resets_at "$resets_at" '{version: 2, windows: {five_hour: {
    used_percentage: 47, resets_at: $resets_at, changed_at: ($now - 100), confirmed: true,
    history: [range(0; 48) | {used_percentage: ., changed_at: ($now - 4800 + . * 10)}]}}}')"
  run rate_limits "$now" write "$SESSION_A" '{"windows":{"five_hour":{"used_percentage":50,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored "$SESSION_A" '.windows.five_hour.history | [length, .[0].used_percentage, .[-1].used_percentage]')" = "[48,1,50]" ] || return 1
}

@test "the reader prints one line per window with its reset, projection and age" {
  local now label expected
  local twelve_thirty=$((MONDAY + 45000)) wednesday_seven=$((MONDAY + 2 * 86400 + 25200))
  local thursday_noon=$((MONDAY + 3 * 86400 + 43200)) saturday_nine=$((MONDAY + 5 * 86400 + 32400))

  # label | now | file (or "none", or "legacy") | expected output
  check_reader() {
    label="$1" now="$2" expected="$4"
    rm -rf "$FOLDER" "$FOLDER.json"
    case $3 in
      none) ;;
      legacy) mkdir -p "${FOLDER%/*}"; reading_json seven_day 60 $((MONDAY + 3 * 86400)) "$now" "[]" >"$FOLDER.json" ;;
      *) put_reading "$SESSION_A" "$3" ;;
    esac
    run rate_limits "$now" read
    [ "$status" -eq 0 ] || { echo "case $label: status $status"; return 1; }
    # shellcheck disable=SC2254 # each expected line is a glob: * stands for the parts a case does not pin
    case $output in
      $expected) ;;
      *) echo "case $label: got '$output', want '$expected'"; return 1 ;;
    esac
  }

  check_reader "rising five_hour" "$twelve_thirty" \
    "$(reading_json five_hour 80 $((MONDAY + 50400)) $((twelve_thirty - 120)) \
      "[{\"used_percentage\":75,\"changed_at\":$((twelve_thirty - 1920))},{\"used_percentage\":80,\"changed_at\":$((twelve_thirty - 120))}]")" \
    "five_hour 80% warning resets 14:00 (in 1h30m) projected 100% at 14:30 after reset changed 2m ago" || return 1

  check_reader "one history entry, 1000 seconds old" "$twelve_thirty" \
    "$(reading_json seven_day 88 $((MONDAY + 3 * 86400)) $((twelve_thirty - 1000)) \
      "[{\"used_percentage\":88,\"changed_at\":$((twelve_thirty - 1000))}]")" \
    "*projected unknown changed 16m ago" || return 1

  check_reader "no reading file" "$twelve_thirty" none "no reading" || return 1
  check_reader "only the legacy file" "$twelve_thirty" legacy "no reading" || return 1

  check_reader "reset on another day" "$wednesday_seven" \
    "$(reading_json seven_day 60 "$saturday_nine" "$wednesday_seven" "[]")" \
    "seven_day 60% resets Sat 09:00 (in 3d2h) *" || return 1

  check_reader "changed two hours ago" "$twelve_thirty" \
    "$(reading_json seven_day 60 $((MONDAY + 3 * 86400)) $((twelve_thirty - 7200)) "[]")" \
    "*changed 2h0m ago" || return 1

  check_reader "rounds to the nearest whole number" "$twelve_thirty" \
    "$(reading_json seven_day 69.7 $((MONDAY + 3 * 86400)) "$twelve_thirty" "[]")" \
    "seven_day 70% *" || return 1

  check_reader "projection on another day, before the reset" "$thursday_noon" \
    "$(reading_json seven_day 70 "$saturday_nine" "$thursday_noon" \
      "[{\"used_percentage\":69,\"changed_at\":$((thursday_noon - 3080))},{\"used_percentage\":70,\"changed_at\":$thursday_noon}]")" \
    "* projected 100% at Fri 13:40 changed 0m ago" || return 1

  # The projection follows the burn rate over the last 60 minutes of history.
  check_reader "rising within the hour" "$twelve_thirty" \
    "$(reading_json seven_day 70 $((MONDAY + 64800)) "$twelve_thirty" \
      "[{\"used_percentage\":60,\"changed_at\":$((twelve_thirty - 1800))},{\"used_percentage\":70,\"changed_at\":$twelve_thirty}]")" \
    "*projected 100% at 14:00 changed*" || return 1

  check_reader "every entry older than 60 minutes" "$twelve_thirty" \
    "$(reading_json seven_day 70 $((MONDAY + 64800)) "$twelve_thirty" \
      "[{\"used_percentage\":60,\"changed_at\":$((twelve_thirty - 7200))},{\"used_percentage\":70,\"changed_at\":$((twelve_thirty - 3700))}]")" \
    "*projected unknown changed*" || return 1

  check_reader "no rise within the hour" "$twelve_thirty" \
    "$(reading_json seven_day 70 $((MONDAY + 64800)) "$twelve_thirty" \
      "[{\"used_percentage\":70,\"changed_at\":$((twelve_thirty - 1800))},{\"used_percentage\":70,\"changed_at\":$twelve_thirty}]")" \
    "*projected unknown changed*" || return 1

  check_reader "unparseable reading file" "$twelve_thirty" "{not json" "no reading" || return 1

  # An expired window reads as reset, with no percentage.
  check_reader "expired window" $((MONDAY + 50401)) \
    "$(reading_json five_hour 92 $((MONDAY + 50400)) $((MONDAY + 50000)) "[]")" \
    "five_hour reset" || return 1
}

@test "a malformed reading is refused and leaves the file byte-identical" {
  local now=1795440000 before label input
  rate_limits "$now" write "$SESSION_A" '{"windows":{"five_hour":{"used_percentage":50,"resets_at":1795449600}}}'
  before="$(cat "$FOLDER/$SESSION_A.json")"
  [ -n "$before" ] || return 1

  while IFS='|' read -r label input; do
    [ -n "$label" ] || continue
    run --separate-stderr rate_limits "$now" write "$SESSION_A" "$input"
    [ "$status" -eq 2 ] || { echo "case $label: status $status"; return 1; }
    [ "$stderr" = "rate-limits: invalid reading" ] || { echo "case $label: stderr '$stderr'"; return 1; }
    [ "$(cat "$FOLDER/$SESSION_A.json")" = "$before" ] || { echo "case $label: file changed"; return 1; }
  done <<'EOF'
not JSON|{windows
no windows|{}
windows not an object|{"windows":[]}
a window not an object|{"windows":{"five_hour":5}}
string percentage|{"windows":{"five_hour":{"used_percentage":"abc","resets_at":1795449600}}}
no percentage|{"windows":{"seven_day":{"resets_at":1795449600}}}
percentage 1000|{"windows":{"five_hour":{"used_percentage":1000,"resets_at":1795449600}}}
percentage -5|{"windows":{"five_hour":{"used_percentage":-5,"resets_at":1795449600}}}
percentage not finite|{"windows":{"five_hour":{"used_percentage":1e400,"resets_at":1795449600}}}
fractional resets_at|{"windows":{"five_hour":{"used_percentage":60,"resets_at":1795449600.5}}}
zero resets_at|{"windows":{"five_hour":{"used_percentage":60,"resets_at":0}}}
milliseconds resets_at|{"windows":{"five_hour":{"used_percentage":60,"resets_at":1795449600000}}}
past the five_hour future bound|{"windows":{"five_hour":{"used_percentage":60,"resets_at":1795458601}}}
past the seven_day future bound|{"windows":{"seven_day":{"used_percentage":60,"resets_at":1796045401}}}
EOF

  # Accepted: paid usage past 100%; any other key and window name is ignored.
  run rate_limits "$now" write "$SESSION_A" '{"source":"desktop","windows":{"five_hour":{"used_percentage":104,"resets_at":1795449600},"Five-Hour":7,"other":{"used_percentage":1}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored "$SESSION_A" '[.windows.five_hour.used_percentage, (.windows | keys), has("source")]')" = '[104,["five_hour"],false]' ] || return 1

  # A window older than its longest length is ignored while the call's other windows are stored.
  run rate_limits "$now" write "$SESSION_A" '{"windows":{"five_hour":{"used_percentage":5,"resets_at":1795421999},"seven_day":{"used_percentage":40,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored "$SESSION_A" '[.windows.five_hour.used_percentage, .windows.seven_day.used_percentage]')" = "[104,40]" ] || return 1
}

@test "a render that repeats the stored figure rewrites nothing, reset drift inside the slack included" {
  local start=1795440000 reset=1795700000 label now resets_at before time
  rate_limits_seed_session "$MAIN" "$SESSION_B" "$start" true seven_day 20 "$reset"
  touch -t 202601010000 "$FOLDER/$SESSION_B.json" "$BATS_TEST_TMPDIR/reference"
  before="$(cat "$FOLDER/$SESSION_B.json")"
  while IFS='|' read -r label now resets_at; do
    [ -n "$label" ] || continue
    run rate_limits "$now" write "$SESSION_B" "{\"windows\":{\"seven_day\":{\"used_percentage\":20,\"resets_at\":$resets_at}}}"
    [ "$status" -eq 0 ] || { echo "case $label: status $status"; return 1; }
    [ "$(cat "$FOLDER/$SESSION_B.json")" = "$before" ] || { echo "case $label: bytes changed"; return 1; }
    [ "$FOLDER/$SESSION_B.json" -nt "$BATS_TEST_TMPDIR/reference" ] && { echo "case $label: modification time moved"; return 1; }
    [ "$BATS_TEST_TMPDIR/reference" -nt "$FOLDER/$SESSION_B.json" ] && { echo "case $label: modification time moved"; return 1; }
  done <<EOF
same reset an hour later|$((start + 3600))|$reset
reset drifted 30 seconds|$((start + 3600))|$((reset + 30))
reset drifted 600 seconds|$((start + 3600))|$((reset - 600))
EOF

  # A flat 80% repeated every minute for 20 minutes reads as changed 20 minutes ago.
  for ((time = start; time <= start + 1200; time += 60)); do
    rate_limits "$time" write "$SESSION_A" '{"windows":{"five_hour":{"used_percentage":80,"resets_at":1795449600}}}' || return 1
  done
  CLAUDE_CODE_SESSION_ID="$SESSION_A" expect_reader "flat figure" $((start + 1200)) "five_hour 80% *changed 20m ago unconfirmed"
}

@test "a reading outside its bounds is refused and a refused render still shows the stored reading" {
  local now=1795440000 before
  prepare_render
  rate_limits_seed_session "$MAIN" "$SESSION_A" $((now - 1000)) true five_hour 50 1795449600 seven_day 80 1795449600
  rate_limits_seed_session "$MAIN" "$SESSION_B" $((now - 10)) true seven_day 22 1795449600
  before="$(cat "$FOLDER/$SESSION_A.json")"

  render "$now" "$SESSION_A" '{"five_hour":{"used_percentage":60,"resets_at":1795458601},"seven_day":{"used_percentage":90,"resets_at":1795449600}}'
  case $PLAIN_OUTPUT in
    *"🕔 50%"*"📅 80%"*) ;;
    *) echo "refused render: $PLAIN_OUTPUT"; return 1 ;;
  esac
  [ "$(cat "$FOLDER/$SESSION_A.json")" = "$before" ] || return 1
}

@test "a reading file that parses but fails validation breaks no reader and the next write repairs it" {
  local now=1795440000 label stored_file reader_expectation repaired
  local beyond_bound=$((now + 30000)) five_hour_reset=$((now + 3600))
  prepare_render

  while IFS='|' read -r label stored_file reader_expectation; do
    [ -n "$label" ] || continue
    # The reader prints only what is valid, the hook is silent, and nothing is stderr noise.
    rm -f "$MARKER"
    put_reading "$HOOK_SESSION" "$stored_file"
    run --separate-stderr rate_limits "$now" read
    [ "$status" -eq 0 ] || { echo "case $label: reader status $status"; return 1; }
    case $output in
      "$reader_expectation"*) ;;
      *) echo "case $label: reader got '$output', want '$reader_expectation'"; return 1 ;;
    esac
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ] || { echo "case $label: reader got '$output'"; return 1; }
    dispatch_hook "$now"
    [ "$status" -eq 0 ] || { echo "case $label: hook status $status"; return 1; }
    [ -z "$output" ] || { echo "case $label: hook spoke: $output"; return 1; }
    [ -z "$stderr" ] || { echo "case $label: hook stderr: $stderr"; return 1; }

    # The render shows its own payload.
    put_reading "$HOOK_SESSION" "$stored_file"
    render "$now" "$HOOK_SESSION" "{\"five_hour\":{\"used_percentage\":55,\"resets_at\":$((now + 3690))}}"
    case $PLAIN_OUTPUT in
      *"55%"*) ;;
      *) echo "case $label: render lost its payload: $PLAIN_OUTPUT"; return 1 ;;
    esac

    # The next write repairs the file.
    put_reading "$HOOK_SESSION" "$stored_file"
    run rate_limits "$now" write "$HOOK_SESSION" "{\"windows\":{\"five_hour\":{\"used_percentage\":95,\"resets_at\":$five_hour_reset}}}"
    [ "$status" -eq 0 ] || { echo "case $label: writer status $status"; return 1; }
    repaired="$(stored "$HOOK_SESSION" '[.version, .windows.five_hour.used_percentage, .windows.five_hour.resets_at]')"
    [ "$repaired" = "[2,95,$five_hour_reset]" ] || { echo "case $label: repaired '$repaired'"; return 1; }
    # Control: the repaired file qualifies, so the hook speaks over it.
    rm -f "$MARKER"
    dispatch_hook "$now"
    [ -n "$output" ] || { echo "case $label: hook silent over the repaired file"; return 1; }
  done <<EOF
a top-level array|[]|no reading
no windows object|{"version":2}|no reading
a string reset beside a valid window|{"version":2,"windows":{"seven_day":{"used_percentage":50,"resets_at":$((now + 90000)),"changed_at":$now,"confirmed":true,"history":[]},"five_hour":{"used_percentage":95,"resets_at":"soon","changed_at":$now,"confirmed":true,"history":[]}}}|seven_day 50%
an older version|{"version":1,"windows":{"five_hour":{"used_percentage":95,"resets_at":$five_hour_reset,"changed_at":$now,"confirmed":true,"history":[]}}}|no reading
a reset past the future bound|{"version":2,"windows":{"five_hour":{"used_percentage":95,"resets_at":$beyond_bound,"changed_at":$now,"confirmed":true,"history":[]}}}|no reading
EOF

  # The string-reset window is dropped and the valid one kept on rewrite.
  put_reading "$SESSION_A" '{"version":2,"windows":{"seven_day":{"used_percentage":50,"resets_at":1795530000,"changed_at":1795440000,"confirmed":true,"history":[]},"five_hour":{"used_percentage":95,"resets_at":"soon","changed_at":1795440000,"confirmed":true,"history":[]}}}'
  run rate_limits "$now" write "$SESSION_A" '{"windows":{"seven_day":{"used_percentage":51,"resets_at":1795530000}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored "$SESSION_A" '.windows | keys')" = '["seven_day"]' ] || { stored "$SESSION_A" '.windows | keys'; return 1; }
}

@test "a session's first reading of a window is stored unconfirmed" {
  local now=1795440000
  run rate_limits "$now" write "$SESSION_C" '{"windows":{"five_hour":{"used_percentage":20,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored "$SESSION_C" '.windows.five_hour | [.used_percentage, .confirmed, .changed_at, (.history | length)]')" = "[20,false,$now,1]" ]
}

@test "outside a session the reader shows the latest change, confirmed before unconfirmed" {
  local now=1795440000 reset=1795449600 t1=1795430000 t2=1795435000 t3=1795438000 index
  local low=11111111-1111-4111-8111-111111111111 high=22222222-2222-4222-8222-222222222222

  rm -rf "$FOLDER"
  rate_limits_seed_session "$MAIN" "$SESSION_A" "$t2" true five_hour 3 "$reset"
  rate_limits_seed_session "$MAIN" "$SESSION_B" "$t1" true five_hour 60 "$reset"
  expect_reader "the later change wins" "$now" "five_hour 3% *" || return 1

  rm -rf "$FOLDER"
  rate_limits_seed_session "$MAIN" "$SESSION_A" "$t1" true five_hour 60 "$reset"
  rate_limits_seed_session "$MAIN" "$SESSION_C" "$t3" false five_hour 20 "$reset"
  expect_reader "confirmed beats a newer unconfirmed" "$now" "five_hour 60% *" || return 1

  rm -rf "$FOLDER"
  rate_limits_seed_session "$MAIN" "$SESSION_C" "$t3" false five_hour 20 "$reset"
  expect_reader "only an unconfirmed entry" "$now" "five_hour 20% *" || return 1

  rm -rf "$FOLDER"
  rate_limits_seed_session "$MAIN" "$SESSION_C" "$t1" false five_hour 40 "$reset"
  rate_limits_seed_session "$MAIN" "$SESSION_D" "$t2" false five_hour 70 "$reset"
  expect_reader "the oldest unconfirmed wins" "$now" "five_hour 40% *" || return 1

  rm -rf "$FOLDER"
  rate_limits_seed_session "$MAIN" "$SESSION_A" "$t2" true five_hour 95 $((now - 10))
  rate_limits_seed_session "$MAIN" "$SESSION_C" "$t1" false five_hour 10 "$reset"
  expect_reader "unexpired beats expired" "$now" "five_hour 10% *" || return 1

  rm -rf "$FOLDER"
  rate_limits_seed_session "$MAIN" "$high" "$t2" true five_hour 50 "$reset"
  rate_limits_seed_session "$MAIN" "$low" "$t2" true five_hour 30 "$reset"
  expect_reader "a tie goes to the lower session id" "$now" "five_hour 30% *" || return 1

  # A reset first seen by a new session shows only once its figure changes.
  rm -rf "$FOLDER"
  rate_limits_seed_session "$MAIN" "$SESSION_B" "$t1" true five_hour 99 "$reset"
  rate_limits "$now" write "$SESSION_E" "{\"windows\":{\"five_hour\":{\"used_percentage\":3,\"resets_at\":$reset}}}" || return 1
  expect_reader "a new session's first figure" "$now" "five_hour 99% *" || return 1
  rate_limits $((now + 60)) write "$SESSION_E" "{\"windows\":{\"five_hour\":{\"used_percentage\":5,\"resets_at\":$reset}}}" || return 1
  expect_reader "the new session's changed figure" $((now + 60)) "five_hour 5% *" || return 1

  # Only the 32 most recently modified files are read.
  rm -rf "$FOLDER"
  rate_limits_seed_session "$MAIN" "$SESSION_A" "$t3" true five_hour 99 "$reset"
  touch -t 202601010000 "$FOLDER/$SESSION_A.json"
  for index in $(seq 10 41); do
    rate_limits_seed_session "$MAIN" "$(printf '%08d-0000-4000-8000-000000000000' "$index")" "$t1" true five_hour 10 "$reset"
  done
  [ "$(find "$FOLDER" -name '*.json' | wc -l | tr -d ' ')" = 33 ] || return 1
  expect_reader "a 33rd, older file" "$now" "five_hour 10% *"
}

@test "inside a session with its own reading the reader prints only that reading, never filling a missing window from another session" {
  local now=$((MONDAY + 43200)) reset=$((MONDAY + 57600)) t1=$((MONDAY + 40000)) t2=$((MONDAY + 41000))

  rate_limits_seed_session "$MAIN" "$SESSION_A" "$t1" true five_hour 40 "$reset"
  rate_limits_seed_session "$MAIN" "$SESSION_B" "$t2" true five_hour 70 "$reset"
  CLAUDE_CODE_SESSION_ID="$SESSION_A" expect_reader "own beats a later change" "$now" "five_hour 40% *" || return 1

  rm -rf "$FOLDER"
  rate_limits_seed_session "$MAIN" "$SESSION_A" "$t1" true five_hour 40 "$reset"
  rate_limits_seed_session "$MAIN" "$SESSION_B" "$t2" true seven_day 22 $((MONDAY + 300000))
  CLAUDE_CODE_SESSION_ID="$SESSION_A" run rate_limits "$now" read
  [ "$status" -eq 0 ] || return 1
  [ "${#lines[@]}" -eq 1 ] || { echo "filled window: $output"; return 1; }
  case ${lines[0]:-} in
    "five_hour 40% "*) ;;
    *) echo "own window: $output"; return 1 ;;
  esac

  # The projection reads only the chosen entry's history.
  rm -rf "$FOLDER"
  put_reading "$SESSION_A" "$(reading_json five_hour 50 "$reset" "$now" "[{\"used_percentage\":40,\"changed_at\":$((now - 1800))},{\"used_percentage\":50,\"changed_at\":$now}]")"
  put_reading "$SESSION_B" "$(reading_json five_hour 90 "$reset" "$now" "[{\"used_percentage\":10,\"changed_at\":$((now - 3600))},{\"used_percentage\":90,\"changed_at\":$now}]")"
  CLAUDE_CODE_SESSION_ID="$SESSION_A" expect_reader "own projection" "$now" "five_hour 50% resets 16:00 * projected 100% at 14:30 changed *"
}

@test "each reader line prints the band word and how long ago the figure changed" {
  local now=$((MONDAY + 43200)) label session file_text profile expected
  local five_hour_reset=$((MONDAY + 52200)) seven_day_reset=$((MONDAY + 300000))
  while IFS='|' read -r label session profile file_text expected; do
    [ -n "$label" ] || continue
    rm -rf "$FOLDER" "$HOME/.claude.json"
    [ "$profile" = "-" ] || printf '{"oauthAccount":{"organizationRateLimitTier":"%s"}}\n' "$profile" >"$HOME/.claude.json"
    put_reading "$SESSION_C" "$file_text"
    if [ "$session" = own ]; then
      CLAUDE_CODE_SESSION_ID="$SESSION_C" expect_reader "$label" "$now" "$expected" || return 1
    else
      expect_reader "$label" "$now" "$expected" || return 1
    fi
  done <<EOF
warning band, changed 5 minutes ago|own|-|$(reading_json five_hour 80 "$five_hour_reset" $((now - 300)) '[]')|five_hour 80% warning resets 14:30 * changed 5m ago
below every band|own|-|$(reading_json seven_day 40 "$seven_day_reset" $((now - 300)) '[]')|seven_day 40% resets *
an expired window|own|-|$(reading_json five_hour 80 $((now - 1)) $((now - 300)) '[]')|five_hour reset
changed 26 hours ago|own|-|$(reading_json seven_day 40 "$seven_day_reset" $((now - 93600)) '[]')|seven_day 40% * changed 26h0m ago
unconfirmed, outside a session|none|-|$(reading_json five_hour 20 "$five_hour_reset" $((now - 300)) '[]' false)|five_hour 20% * changed 5m ago unconfirmed
the largest tier below its warning|own|default_claude_max_20x|$(reading_json seven_day 84 "$seven_day_reset" $((now - 300)) '[]')|seven_day 84% resets *
the largest tier at its critical|own|default_claude_max_20x|$(reading_json seven_day 95 "$seven_day_reset" $((now - 300)) '[]')|seven_day 95% critical resets *
EOF
}

@test "the write verb refuses a non-UUID session id and the one-argument form" {
  local label
  while IFS='|' read -r label; do
    [ -n "$label" ] || continue
    case $label in
      "a path-shaped id") run --separate-stderr rate_limits 1795440000 write ../x '{"windows":{"five_hour":{"used_percentage":5,"resets_at":1795449600}}}' ;;
      "no session id") run --separate-stderr rate_limits 1795440000 write '{"windows":{"five_hour":{"used_percentage":5,"resets_at":1795449600}}}' ;;
    esac
    [ "$status" -eq 2 ] || { echo "case $label: status $status"; return 1; }
    case $stderr in
      usage:*"write <session-id> <input-json>"*) ;;
      *) echo "case $label: stderr '$stderr'"; return 1 ;;
    esac
    [ -e "$MAIN/.gaia/local" ] && { echo "case $label: wrote under .gaia/local"; return 1; }
    [ -e "$MAIN/x" ] && { echo "case $label: wrote a path from the id"; return 1; }
  done <<'EOF'
a path-shaped id
no session id
EOF
  true
}

@test "a non-UUID session id never forms a path in the render, the reader or the hook" {
  local now=1795440000 before after expected

  # The writer refuses the id and creates nothing.
  run writer_records "$now" ../x '{"windows":{"five_hour":{"used_percentage":40,"resets_at":1795449600}}}'
  [ "$output" = "rc=1" ] || { echo "writer: $output"; return 1; }
  [ -e "$MAIN/.gaia/local" ] && return 1

  # The render shows its payload and changes nothing under .gaia/local.
  prepare_render
  before=$(find "$MAIN/.gaia/local" -type f -exec cksum {} + | sort)
  render "$now" "../../x" '{"five_hour":{"used_percentage":40,"resets_at":1795449600}}'
  after=$(find "$MAIN/.gaia/local" -type f -exec cksum {} + | sort)
  [ "$after" = "$before" ] || { echo "files changed: $after"; return 1; }
  case $PLAIN_OUTPUT in
    *"🕔 40%"*) ;;
    *) echo "render: $PLAIN_OUTPUT"; return 1 ;;
  esac

  # The reader treats the id as absent.
  rate_limits_seed_session "$MAIN" "$SESSION_A" $((now - 60)) true five_hour 30 1795449600
  run rate_limits "$now" read
  expected="$output"
  CLAUDE_CODE_SESSION_ID=../x run rate_limits "$now" read
  [ "$output" = "$expected" ] || { echo "reader: '$output' want '$expected'"; return 1; }
  case $output in "five_hour 30% "*) ;; *) echo "reader: $output"; return 1 ;; esac

  # The hook is silent although a window is due in a session's file.
  rate_limits_seed_session "$MAIN" "$HOOK_SESSION" $((now - 60)) true five_hour 91 1795449600
  dispatch_hook "$now" ../x
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || { echo "hook spoke: $output"; return 1; }
}

@test "an entry failing the validity rule is skipped and the next valid entry is shown" {
  local now=1795440000 reset=1795449600 t1=1795430000 label file_name file_text expected
  while IFS='|' read -r label file_name file_text expected; do
    [ -n "$label" ] || continue
    rm -rf "$FOLDER"
    [ "$expected" = "no reading" ] || rate_limits_seed_session "$MAIN" "$SESSION_A" "$t1" true five_hour 30 "$reset"
    mkdir -p "$FOLDER"
    printf '%s\n' "$file_text" >"$FOLDER/$file_name"
    expect_reader "$label" "$now" "$expected" || return 1
  done <<EOF
changed_at far in the future|$SESSION_E.json|$(reading_json five_hour 99 "$reset" 4102444800 '[]')|five_hour 30% *
version 1|$SESSION_E.json|{"version":1,"windows":{"five_hour":{"used_percentage":99,"resets_at":$reset,"changed_at":$now,"confirmed":true,"history":[]}}}|five_hour 30% *
confirmed not a boolean|$SESSION_E.json|$(reading_json five_hour 99 "$reset" "$now" '[]' '"yes"')|no reading
a negative figure|$SESSION_E.json|$(reading_json five_hour -5 "$reset" "$now" '[]')|no reading
an unparseable file|$SESSION_E.json|{|five_hour 30% *
a file not named by a session id|notes.json|$(reading_json five_hour 99 "$reset" "$now" '[]')|five_hour 30% *
EOF
}

# jq_shim <log>: a jq on PATH that logs each call, and each profile it is handed, then runs the real one.
jq_shim() {
  local real_jq
  real_jq=$(command -v jq)
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  cat >"$BATS_TEST_TMPDIR/shim/jq" <<EOF
#!/bin/bash
printf 'call\n' >>"$1"
for argument in "\$@"; do
  case \$argument in *.claude.json) printf 'profile\n' >>"$1" ;; esac
done
exec "$real_jq" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/shim/jq"
  : >"$1"
}

@test "the profile is opened only by banding at or above the lowest 7-day warning" {
  local now=1795440000 reset=1795900000 log="$BATS_TEST_TMPDIR/jq.log" sentinel="$BATS_TEST_TMPDIR/sentinel"
  mkdir -p "$sentinel"
  printf '{"oauthAccount":{"organizationRateLimitTier":"default_claude_max_20x"}}\n' >"$sentinel/.claude.json"
  jq_shim "$log"
  prepare_render

  # A render never opens it, even at 96%, and nor does its writer.
  rate_limits_seed_session "$MAIN" "$HOOK_SESSION" $((now - 60)) true seven_day 96 "$reset"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" CLAUDE_CONFIG_DIR="$sentinel" \
    render "$now" "$HOOK_SESSION" "{\"seven_day\":{\"used_percentage\":96,\"resets_at\":$reset}}"
  grep -q profile "$log" && { echo "the render opened the profile"; return 1; }
  : >"$log"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" CLAUDE_CONFIG_DIR="$sentinel" \
    run writer_records "$now" "$HOOK_SESSION" "{\"windows\":{\"seven_day\":{\"used_percentage\":97,\"resets_at\":$reset}}}"
  grep -q profile "$log" && { echo "the writer opened the profile"; return 1; }

  # Below the lowest warning the hook and the reader never open it.
  rate_limits_seed_session "$MAIN" "$HOOK_SESSION" $((now - 60)) true seven_day 74 "$reset"
  : >"$log"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" CLAUDE_CONFIG_DIR="$sentinel" dispatch_hook "$now"
  [ "$status" -eq 0 ] || return 1
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" CLAUDE_CONFIG_DIR="$sentinel" \
    CLAUDE_CODE_SESSION_ID="$HOOK_SESSION" expect_reader "74% in the session" "$now" "seven_day 74% resets *" || return 1
  grep -q profile "$log" && { echo "opened below the warning"; return 1; }
  # Control: at the lowest warning the hook opens it.
  rate_limits_seed_session "$MAIN" "$HOOK_SESSION" $((now - 60)) true seven_day 75 "$reset"
  rm -f "$MARKER"
  : >"$log"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" CLAUDE_CONFIG_DIR="$sentinel" dispatch_hook "$now"
  [ "$status" -eq 0 ] || return 1
  grep -q profile "$log"
}

@test "a dispatch that sees a fall lowers the marked band so the next climb speaks" {
  local now=1795440000 reset=1795449600 label marked percentage want_speech want_band want_reset before
  mkdir -p "${MARKER%/*}"

  # Each case: the marker before the dispatch, the figure, whether the hook speaks, and the marker after.
  while IFS='|' read -r label marked percentage want_speech want_band want_reset; do
    [ -n "$label" ] || continue
    printf '%s\n' "$marked" >"$MARKER"
    rate_limits_seed_session "$MAIN" "$HOOK_SESSION" $((now - 60)) true five_hour "$percentage" "$reset"
    dispatch_hook "$now"
    [ "$status" -eq 0 ] || { echo "case $label: status $status"; return 1; }
    case $want_speech in
      -) [ -z "$output" ] || { echo "case $label: spoke: $output"; return 1; } ;;
      *) grep -qF "Rate-limit checkpoint: five_hour $want_speech band ($percentage%), " <<<"$output" || { echo "case $label: got '$output'"; return 1; } ;;
    esac
    [ "$(jq -c '[.five_hour.band, .five_hour.resets_at]' "$MARKER")" = "[\"$want_band\",$want_reset]" ] || { echo "case $label: marker $(cat "$MARKER")"; return 1; }
  done <<EOF
a rise above the marked band|{"five_hour":{"resets_at":$reset,"band":"warning"}}|91|critical|critical|$reset
a fall to clear|{"five_hour":{"resets_at":$reset,"band":"critical"}}|40|-|clear|$reset
a fall to warning|{"five_hour":{"resets_at":$reset,"band":"critical"}}|80|-|warning|$reset
a reset time past the slack starts from clear|{"five_hour":{"resets_at":$((reset - 601)),"band":"critical"}}|80|warning|warning|$reset
an unchanged band|{"five_hour":{"resets_at":$reset,"band":"warning"}}|80|-|warning|$reset
EOF

  # Through the hook: a fall it sees re-arms the band; one it never sees does not.
  printf '{"five_hour":{"resets_at":%s,"band":"critical"}}\n' "$reset" >"$MARKER"
  rate_limits_seed_session "$MAIN" "$HOOK_SESSION" $((now - 60)) true five_hour 40 "$reset"
  dispatch_hook "$now"
  [ -z "$output" ] || { echo "fall spoke: $output"; return 1; }
  [ "$(jq -c '.five_hour.band' "$MARKER")" = '"clear"' ] || { echo "marker: $(cat "$MARKER")"; return 1; }
  rate_limits_seed_session "$MAIN" "$HOOK_SESSION" "$now" true five_hour 91 "$reset"
  dispatch_hook "$now"
  grep -qF 'Rate-limit checkpoint: five_hour critical band (91%), ' <<<"$output" || { echo "climb: $output"; return 1; }

  printf '{"five_hour":{"resets_at":%s,"band":"critical"}}\n' "$reset" >"$MARKER"
  touch -t 202601010000 "$MARKER"
  before="$(cat "$MARKER")"
  rate_limits_seed_session "$MAIN" "$HOOK_SESSION" "$now" true five_hour 91 "$reset"
  dispatch_hook "$now"
  [ -z "$output" ] || { echo "unseen fall spoke: $output"; return 1; }
  [ "$(cat "$MARKER")" = "$before" ] || return 1
  [ "$MARKER" -nt "$FOLDER/$HOOK_SESSION.json" ] && return 1
  true
}

@test "nothing from the profile but the band reaches the hook's or the reader's output, a file or the temporary folder" {
  local now=1795440000 reset=1795900000 label percentage want_header profile_text secret hook_all reader_all
  local email=person@example.com uuid=00000000-0000-4000-8000-000000000000
  local profile_dir="$BATS_TEST_TMPDIR/profile" scratch="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$profile_dir" "$scratch"
  export CLAUDE_CONFIG_DIR="$profile_dir" TMPDIR="$scratch"

  # Each probe proves its check can fail: the needle is found where it sits.
  printf 'the ultra set\n' >"$scratch/probe"
  grep -rEiqw 'ultra|max|standard' "$scratch" || { echo "the band-set check cannot fail"; return 1; }
  printf 'x %s y\n' "$email" >"$scratch/probe"
  grep -rqF -e "$email" "$scratch" || { echo "the secret check cannot fail"; return 1; }
  rm -f "$scratch/probe"

  while IFS='|' read -r label percentage want_header profile_text; do
    [ -n "$label" ] || continue
    printf '%s\n' "$profile_text" >"$profile_dir/.claude.json"
    rm -rf "$MAIN/.gaia/local"
    rm -f "$scratch"/*
    rate_limits_seed_session "$MAIN" "$HOOK_SESSION" $((now - 60)) true seven_day "$percentage" "$reset"

    dispatch_hook "$now"
    [ "$status" -eq 0 ] || { echo "case $label: hook status $status"; return 1; }
    grep -qF "Rate-limit checkpoint: $want_header, " <<<"$output" || { echo "case $label: header: $output"; return 1; }
    hook_all="$output$stderr"
    run --separate-stderr rate_limits "$now" read
    [ "$status" -eq 0 ] || { echo "case $label: reader status $status"; return 1; }
    reader_all="$output$stderr"

    for secret in "$email" "$uuid" default_claude_max_20x; do
      grep -qF -e "$secret" <<<"$hook_all" && { echo "case $label: hook leaked $secret"; return 1; }
      grep -qF -e "$secret" <<<"$reader_all" && { echo "case $label: reader leaked $secret"; return 1; }
      if grep -rqF -e "$secret" "$MAIN/.gaia/local" "$scratch"; then
        echo "case $label: $secret written to $(grep -rlF -e "$secret" "$MAIN/.gaia/local" "$scratch")"
        return 1
      fi
    done
    grep -Eiqw 'ultra|max|standard' <<<"$hook_all" && { echo "case $label: hook named a band set: $hook_all"; return 1; }
    grep -Eiqw 'ultra|max|standard' <<<"$reader_all" && { echo "case $label: reader named a band set: $reader_all"; return 1; }
    rm -f "$MARKER"
  done <<EOF
identity and a 20x tier|96|seven_day critical band (96%)|{"oauthAccount":{"emailAddress":"$email","accountUuid":"$uuid","organizationRateLimitTier":"default_claude_max_20x"}}
tier held as an object|76|seven_day warning band (76%)|{"oauthAccount":{"organizationRateLimitTier":{"owner":"$email"}}}
broken JSON after the email|91|seven_day critical band (91%)|"emailAddress":"$email",{ broken
EOF
  true
}

@test "after a limit reset the dispatch and the reader follow the lower figure, and an idle session's statusline keeps its own" {
  local now=1795440000 reset=1795449600 five_hour
  prepare_render

  # Both sessions render a climb, so both readings are confirmed.
  for five_hour in 98 99; do
    render "$now" "$SESSION_A" "{\"five_hour\":{\"used_percentage\":$five_hour,\"resets_at\":$reset}}"
    now=$((now + 60))
    render "$now" "$SESSION_B" "{\"five_hour\":{\"used_percentage\":$five_hour,\"resets_at\":$reset}}"
    now=$((now + 60))
  done

  dispatch_hook "$now" "$SESSION_A"
  grep -qF 'Rate-limit checkpoint: five_hour critical band (99%), ' <<<"$output" || { echo "first dispatch: $output"; return 1; }

  # The limit resets: A's next response carries the lower figure.
  now=$((now + 60))
  render "$now" "$SESSION_A" "{\"five_hour\":{\"used_percentage\":3,\"resets_at\":$reset}}"
  now=$((now + 60))
  dispatch_hook "$now" "$SESSION_A"
  [ -z "$output" ] || { echo "dispatch after the reset spoke: $output"; return 1; }

  # Idle B repeats its old figure; that changes nothing, and its own statusline
  # keeps it, since another session's file may belong to another account.
  now=$((now + 60))
  render "$now" "$SESSION_B" "{\"five_hour\":{\"used_percentage\":99,\"resets_at\":$reset}}"
  grep -qF "🕔 99%" <<<"$PLAIN_OUTPUT" || { echo "B's left side: $PLAIN_OUTPUT"; return 1; }
  run rate_limits "$now" read
  [ "$status" -eq 0 ] || return 1
  case ${lines[0]:-} in
    "five_hour 3% "*) ;;
    *) echo "reader: $output"; return 1 ;;
  esac
}
