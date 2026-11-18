#!/usr/bin/env bats
#
# Suite for .gaia/scripts/rate-limits.sh and the library behind it: the merge
# rule, history, validation, the rewrite skip and the reader's lines, driven
# through the CLI in a scratch git checkout with the clock and TZ pinned.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/rate-limits.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# Monday 2026-11-23 00:00 UTC; every reader case runs under TZ=UTC.
MONDAY=1795392000

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI="$REPO_ROOT/.gaia/scripts/rate-limits.sh"
  MAIN="$BATS_TEST_TMPDIR/main"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  FILE="$MAIN/.gaia/local/cache/shared/rate-limits.json"
  export TZ=UTC
}

# rate_limits <now> <verb> [<input-json>]: the CLI as a session in MAIN runs it.
rate_limits() {
  local now="$1"
  shift
  (cd "$MAIN" && GAIA_RATE_LIMITS_NOW="$now" bash "$CLI" "$@")
}

put_file() {
  mkdir -p "${FILE%/*}"
  printf '%s\n' "$1" >"$FILE"
}

stored() {
  jq -c "$1" "$FILE"
}

# window_json <name> <percentage> <resets_at> <observed_at> <history-json>
window_json() {
  printf '{"version":1,"windows":{"%s":{"used_percentage":%s,"resets_at":%s,"observed_at":%s,"producer":"statusline","history":%s}}}' "$@"
}

@test "a same-window reading raises the stored figure and never lowers it" {
  local now=1795440000
  run rate_limits "$now" write '{"producer":"statusline","windows":{"seven_day":{"used_percentage":80,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.version')" = "1" ] || return 1
  [ "$(stored '.windows.seven_day | [.used_percentage, .resets_at]')" = "[80,1795449600]" ] || return 1

  run rate_limits "$now" write '{"producer":"statusline","windows":{"seven_day":{"used_percentage":90,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.windows.seven_day | [.used_percentage, .resets_at]')" = "[90,1795449600]" ] || return 1

  run rate_limits "$now" write '{"producer":"statusline","windows":{"seven_day":{"used_percentage":80,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.windows.seven_day | [.used_percentage, .resets_at]')" = "[90,1795449600]" ] || return 1

  # Reset times 600 seconds apart are one window: the higher figure stays, the later reset is kept.
  run rate_limits "$now" write '{"producer":"statusline","windows":{"seven_day":{"used_percentage":85,"resets_at":1795450200}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.windows.seven_day | [.used_percentage, .resets_at]')" = "[90,1795450200]" ] || return 1

  # The producer never changes the decision: a lower mod reading of the same window loses.
  run rate_limits "$now" write '{"producer":"mod","windows":{"seven_day":{"used_percentage":70,"resets_at":1795450200}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.windows.seven_day | [.used_percentage, .producer]')" = '[90,"statusline"]' ] || return 1
}

@test "a later window replaces the stored one and an earlier window is ignored" {
  local now=1795449000 three_entries before
  three_entries='[{"used_percentage":80,"observed_at":1795448000,"producer":"statusline"},{"used_percentage":88,"observed_at":1795448500,"producer":"statusline"},{"used_percentage":92,"observed_at":1795448900,"producer":"statusline"}]'

  put_file "$(window_json five_hour 92 1795449600 1795448900 "$three_entries")"
  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":3,"resets_at":1795467600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.windows.five_hour | [.used_percentage, .resets_at, (.history | length)]')" = "[3,1795467600,1]" ] || return 1

  before="$(cat "$FILE")"
  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":95,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(cat "$FILE")" = "$before" ] || return 1

  # 601 seconds later replaces.
  put_file "$(window_json five_hour 92 1795449600 1795448900 "$three_entries")"
  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":3,"resets_at":1795450201}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.windows.five_hour | [.used_percentage, .resets_at, (.history | length)]')" = "[3,1795450201,1]" ] || return 1

  # 601 seconds earlier is ignored.
  put_file "$(window_json five_hour 3 1795467600 1795448900 '[{"used_percentage":3,"observed_at":1795448900,"producer":"statusline"}]')"
  before="$(cat "$FILE")"
  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":95,"resets_at":1795466999}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(cat "$FILE")" = "$before" ] || return 1
}

@test "a rise appends one history entry and history keeps the newest 48" {
  local now=1795440000 resets_at=1795449600

  put_file "$(window_json five_hour 40 "$resets_at" $((now - 300)) '[{"used_percentage":40,"observed_at":1795439700,"producer":"statusline"}]')"
  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":40,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.windows.five_hour.history | length')" = "1" ] || return 1

  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":42,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.windows.five_hour.history | length')" = "2" ] || return 1
  [ "$(stored '.windows.five_hour.history[-1]')" = '{"used_percentage":42,"observed_at":1795440000,"producer":"statusline"}' ] || return 1

  put_file "$(jq -nc --argjson now "$now" --argjson resets_at "$resets_at" '{version: 1, windows: {five_hour: {
    used_percentage: 47, resets_at: $resets_at, observed_at: ($now - 100), producer: "statusline",
    history: [range(0; 48) | {used_percentage: ., observed_at: ($now - 4800 + . * 10), producer: "statusline"}]}}}')"
  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":50,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.windows.five_hour.history | [length, .[0].used_percentage, .[-1].used_percentage]')" = "[48,1,50]" ] || return 1
}

@test "the reader prints one line per window with its reset, projection and age" {
  local now label expected
  local twelve_thirty=$((MONDAY + 45000)) wednesday_seven=$((MONDAY + 2 * 86400 + 25200))
  local thursday_noon=$((MONDAY + 3 * 86400 + 43200)) saturday_nine=$((MONDAY + 5 * 86400 + 32400))

  # label | now | file (or "none") | expected output
  check_reader() {
    label="$1" now="$2" expected="$4"
    rm -f "$FILE"
    [ "$3" = "none" ] || put_file "$3"
    run rate_limits "$now" read
    [ "$status" -eq 0 ] || { echo "case $label: status $status"; return 1; }
    # shellcheck disable=SC2254 # each expected line is a glob: * stands for the parts a case does not pin
    case $output in
      $expected) ;;
      *) echo "case $label: got '$output', want '$expected'"; return 1 ;;
    esac
  }

  check_reader "rising five_hour" "$twelve_thirty" \
    "$(window_json five_hour 80 $((MONDAY + 50400)) $((twelve_thirty - 120)) \
      "[{\"used_percentage\":75,\"observed_at\":$((twelve_thirty - 1920)),\"producer\":\"statusline\"},{\"used_percentage\":80,\"observed_at\":$((twelve_thirty - 120)),\"producer\":\"statusline\"}]")" \
    "five_hour 80% resets 14:00 (in 1h30m) projected 100% at 14:30 after reset as of 2m ago" || return 1

  check_reader "one history entry, 1000 seconds old" "$twelve_thirty" \
    "$(window_json seven_day 88 $((MONDAY + 3 * 86400)) $((twelve_thirty - 1000)) \
      "[{\"used_percentage\":88,\"observed_at\":$((twelve_thirty - 1000)),\"producer\":\"statusline\"}]")" \
    "*projected unknown as of 16m ago stale" || return 1

  check_reader "no shared file" "$twelve_thirty" none "no reading" || return 1

  check_reader "reset on another day" "$wednesday_seven" \
    "$(window_json seven_day 88 "$saturday_nine" "$wednesday_seven" "[]")" \
    "seven_day 88% resets Sat 09:00 (in 3d2h) *" || return 1

  check_reader "observed two hours ago" "$twelve_thirty" \
    "$(window_json seven_day 88 $((MONDAY + 3 * 86400)) $((twelve_thirty - 7200)) "[]")" \
    "*as of 2h0m ago stale" || return 1

  check_reader "rounds to the nearest whole number" "$twelve_thirty" \
    "$(window_json seven_day 89.7 $((MONDAY + 3 * 86400)) "$twelve_thirty" "[]")" \
    "seven_day 90% *" || return 1

  check_reader "projection on another day, before the reset" "$thursday_noon" \
    "$(window_json seven_day 70 "$saturday_nine" "$thursday_noon" \
      "[{\"used_percentage\":69,\"observed_at\":$((thursday_noon - 3080)),\"producer\":\"statusline\"},{\"used_percentage\":70,\"observed_at\":$thursday_noon,\"producer\":\"statusline\"}]")" \
    "* projected 100% at Fri 13:40 as of 0m ago" || return 1

  check_reader "unparseable shared file" "$twelve_thirty" "{not json" "no reading" || return 1

  # An expired window reads as reset, with no percentage.
  check_reader "expired window" $((MONDAY + 50401)) \
    "$(window_json five_hour 92 $((MONDAY + 50400)) $((MONDAY + 50000)) "[]")" \
    "five_hour reset" || return 1
}

@test "a malformed reading is refused and leaves the file byte-identical" {
  local now=1795440000 before label input windows_nine index
  rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":50,"resets_at":1795449600}}}'
  before="$(cat "$FILE")"
  [ -n "$before" ] || return 1

  windows_nine=""
  for index in 1 2 3 4 5 6 7 8 9; do
    windows_nine="$windows_nine${windows_nine:+,}\"window_$index\":{\"used_percentage\":10,\"resets_at\":1795449600}"
  done

  while IFS='|' read -r label input; do
    [ -n "$label" ] || continue
    run --separate-stderr rate_limits "$now" write "$input"
    [ "$status" -eq 2 ] || { echo "case $label: status $status"; return 1; }
    [ "$stderr" = "rate-limits: invalid reading" ] || { echo "case $label: stderr '$stderr'"; return 1; }
    [ "$(cat "$FILE")" = "$before" ] || { echo "case $label: file changed"; return 1; }
  done <<EOF
string percentage|{"windows":{"five_hour":{"used_percentage":"abc","resets_at":1795449600}}}
name outside the rule|{"producer":"statusline","windows":{"Five-Hour":{"used_percentage":50,"resets_at":1795449600}}}
unknown producer|{"producer":"desktop","windows":{"five_hour":{"used_percentage":60,"resets_at":1795449600}}}
no producer|{"windows":{"five_hour":{"used_percentage":60,"resets_at":1795449600}}}
no resets_at|{"producer":"statusline","windows":{"five_hour":{"used_percentage":60}}}
more than 8 windows|{"producer":"statusline","windows":{$windows_nine}}
percentage 1000|{"producer":"statusline","windows":{"five_hour":{"used_percentage":1000,"resets_at":1795449600}}}
percentage -5|{"producer":"statusline","windows":{"five_hour":{"used_percentage":-5,"resets_at":1795449600}}}
percentage not finite|{"producer":"statusline","windows":{"five_hour":{"used_percentage":1e400,"resets_at":1795449600}}}
fractional resets_at|{"producer":"statusline","windows":{"five_hour":{"used_percentage":60,"resets_at":1795449600.5}}}
zero resets_at|{"producer":"statusline","windows":{"five_hour":{"used_percentage":60,"resets_at":0}}}
milliseconds resets_at|{"producer":"statusline","windows":{"five_hour":{"used_percentage":60,"resets_at":1795449600000}}}
past the five_hour future bound|{"producer":"statusline","windows":{"five_hour":{"used_percentage":60,"resets_at":1795458601}}}
past the seven_day future bound|{"producer":"statusline","windows":{"seven_day":{"used_percentage":60,"resets_at":1796045401}}}
EOF

  # Accepted: paid usage past 100%, and an input observed_at the writer ignores.
  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":104,"resets_at":1795449600,"observed_at":1}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.windows.five_hour | [.used_percentage, .observed_at]')" = "[104,1795440000]" ] || return 1

  # A window older than its longest length is ignored while the call's other windows merge.
  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":5,"resets_at":1795421999},"seven_day":{"used_percentage":40,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '[.windows.five_hour.used_percentage, .windows.seven_day.used_percentage]')" = "[104,40]" ] || return 1
}

@test "an equal reading advances the last-observed time and skips a rewrite within 60 seconds" {
  local now=1795440000 before_bytes before_inode time

  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":80,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '[.version, (.windows.five_hour | keys)]')" = '[1,["history","observed_at","producer","resets_at","used_percentage"]]' ] || return 1

  put_file "$(window_json five_hour 40 1795449600 $((now - 300)) '[{"used_percentage":40,"observed_at":1795439700,"producer":"statusline"}]')"
  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":40,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(stored '.windows.five_hour | [.observed_at, (.history | length)]')" = "[1795440000,1]" ] || return 1

  put_file "$(window_json five_hour 40 1795449600 $((now - 30)) '[{"used_percentage":40,"observed_at":1795439970,"producer":"statusline"}]')"
  before_bytes="$(cat "$FILE")"
  before_inode="$(ls -i "$FILE")"
  run rate_limits "$now" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":40,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "$(cat "$FILE")" = "$before_bytes" ] || return 1
  [ "$(ls -i "$FILE")" = "$before_inode" ] || return 1

  # A flat 80% confirmed every 15 seconds for 20 minutes reads as fresh.
  rm -f "$FILE"
  for ((time = now; time <= now + 1200; time += 15)); do
    rate_limits "$time" write '{"producer":"statusline","windows":{"five_hour":{"used_percentage":80,"resets_at":1795449600}}}' || return 1
  done
  run rate_limits $((now + 1200)) read
  [ "$status" -eq 0 ] || return 1
  case $output in
    *" as of 0m ago" | *" as of 1m ago") ;;
    *) echo "got '$output'"; return 1 ;;
  esac
}

@test "the projection follows the burn rate over the last 60 minutes" {
  local now=$((MONDAY + 45000)) label history resets_at expected
  while IFS='|' read -r label resets_at history expected; do
    [ -n "$label" ] || continue
    put_file "$(window_json seven_day 70 "$resets_at" "$now" "$history")"
    run rate_limits "$now" read
    [ "$status" -eq 0 ] || { echo "case $label: status $status"; return 1; }
    case $output in
      *"$expected"*) ;;
      *) echo "case $label: got '$output', want '$expected'"; return 1 ;;
    esac
  done <<EOF
rising within the hour|$((MONDAY + 64800))|[{"used_percentage":60,"observed_at":$((now - 1800)),"producer":"statusline"},{"used_percentage":70,"observed_at":$now,"producer":"statusline"}]|projected 100% at 14:00 as of
every entry older than 60 minutes|$((MONDAY + 64800))|[{"used_percentage":60,"observed_at":$((now - 7200)),"producer":"statusline"},{"used_percentage":70,"observed_at":$((now - 3700)),"producer":"statusline"}]|projected unknown as of
no rise within the hour|$((MONDAY + 64800))|[{"used_percentage":70,"observed_at":$((now - 1800)),"producer":"statusline"},{"used_percentage":70,"observed_at":$now,"producer":"statusline"}]|projected unknown as of
projection past the reset|$((MONDAY + 48600))|[{"used_percentage":60,"observed_at":$((now - 1800)),"producer":"statusline"},{"used_percentage":70,"observed_at":$now,"producer":"statusline"}]|projected 100% at 14:00 after reset as of
EOF
}

# writer_records <now> <input-json>: the library writer's display records on
# stdout, then its return code as `rc=<n>`; the writer's stderr is dropped.
writer_records() {
  GAIA_RATE_LIMITS_NOW="$1" bash -c '
    . "$1/.gaia/scripts/rate-limits-lib.sh"
    gaia_rate_limits_write "$2" "$3" "$4" 2>/dev/null
    printf "rc=%s\n" "$?"
  ' _ "$REPO_ROOT" "$MAIN" "$1" "$2"
}

@test "a reading outside its bounds is refused and a refused render still shows the higher figure" {
  local now=1795440000 before label input
  put_file '{"version":1,"windows":{"five_hour":{"used_percentage":50,"resets_at":1795449600,"observed_at":1795439000,"producer":"statusline","history":[]},"seven_day":{"used_percentage":80,"resets_at":1795449600,"observed_at":1795439000,"producer":"statusline","history":[]}}}'
  before="$(cat "$FILE")"

  # Each reading is out of bounds: refused with the exact stderr, file byte-identical.
  while IFS='|' read -r label input; do
    [ -n "$label" ] || continue
    run --separate-stderr rate_limits "$now" write "$input"
    [ "$status" -eq 2 ] || { echo "case $label: status $status"; return 1; }
    [ "$stderr" = "rate-limits: invalid reading" ] || { echo "case $label: stderr '$stderr'"; return 1; }
    [ "$(cat "$FILE")" = "$before" ] || { echo "case $label: file changed"; return 1; }
  done <<'CASES'
percentage 1000|{"producer":"statusline","windows":{"five_hour":{"used_percentage":1000,"resets_at":1795449600}}}
percentage -5|{"producer":"statusline","windows":{"five_hour":{"used_percentage":-5,"resets_at":1795449600}}}
milliseconds resets_at|{"producer":"statusline","windows":{"five_hour":{"used_percentage":60,"resets_at":1795449600000}}}
past the five_hour future bound|{"producer":"statusline","windows":{"five_hour":{"used_percentage":60,"resets_at":1795458601}}}
past the seven_day future bound|{"producer":"statusline","windows":{"seven_day":{"used_percentage":60,"resets_at":1796045401}}}
past the future bound of another name|{"producer":"statusline","windows":{"other":{"used_percentage":60,"resets_at":1796045401}}}
CASES

  # The refused write's display: the stored seven_day is raised to the well-formed
  # same-window figure, the out-of-bounds five_hour changes nothing stored, and a
  # well-formed window the file lacks is shown.
  run writer_records "$now" '{"producer":"statusline","windows":{"five_hour":{"used_percentage":1000,"resets_at":1795449600},"seven_day":{"used_percentage":90,"resets_at":1795449600},"extra":{"used_percentage":30,"resets_at":1795449600}}}'
  [ "$status" -eq 0 ] || return 1
  [ "${lines[0]}" = "$(printf 'extra\t30\t1795449600\tlive')" ] || { echo "records: $output"; return 1; }
  [ "${lines[1]}" = "$(printf 'five_hour\t50\t1795449600\tlive')" ] || { echo "records: $output"; return 1; }
  [ "${lines[2]}" = "$(printf 'seven_day\t90\t1795449600\tlive')" ] || { echo "records: $output"; return 1; }
  [ "${lines[3]}" = "rc=2" ] || { echo "records: $output"; return 1; }
  [ "$(cat "$FILE")" = "$before" ] || return 1
}
