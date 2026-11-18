# shellcheck shell=bash
#
# Shared rate-limit reading lib. The ONE place the account's rate-limit windows
# (the 5-hour and 7-day usage figures, and any other named window) are stored,
# merged and rendered as text, and the ONE definition of the warning and
# critical bands the statusline and the dispatch checkpoint both use.
#
# Owns: the shared file (<main>/.gaia/local/cache/shared/rate-limits.json, one
# per checkout, reached from every linked worktree), its one writer
# (gaia_rate_limits_write: validate, merge, atomic replace), its one reader
# (gaia_rate_limits_report: reader lines, due bands, the merged marker body),
# the bands, the merge and staleness windows, and the clock override.
# Does not own: turning a statusline payload into a reading (the statusline
# does that and calls the writer), drawing the usage segments, the dispatch
# checkpoint's marker file (its hook writes the body this lib computes), or
# the policy for acting on a reading.
#
# Record shape, producer-neutral. A producer normalizes its source into
#   {"producer":"statusline","windows":{"five_hour":{"used_percentage":80,"resets_at":1795449600}}}
# where each window name is lowercase letters, digits and underscores (1-32),
# used_percentage is a number in 0..999 and resets_at is epoch seconds. A
# window the source has no reading for is left out, never sent as 0. The
# stored file is
#   {"version":1,"windows":{"five_hour":{"used_percentage":80,"resets_at":1795449600,
#     "observed_at":1795440000,"producer":"statusline",
#     "history":[{"used_percentage":80,"observed_at":1795440000,"producer":"statusline"}]}}}
# `producer` is `statusline` or `mod` and is provenance only: it never decides
# a merge, staleness or anything a reader does. `observed_at` is stamped by the
# writer from its caller's clock; an `observed_at` in the input is ignored.
#
# Merge rule per window name, no timestamp trusted for ordering: reset times
# within GAIA_RATE_LIMITS_SAME_WINDOW_SECONDS are one window (the higher
# percentage wins, the later reset is kept); a reset more than that later
# replaces the window, history included; one more than that earlier is ignored.
# A lower reading of the same window moves only a later reset time; it never
# marks the stored figure freshly observed.
#
# No lock. Two writers racing can drop the higher value for one render; the
# next render of the session holding it restores it. Each write is atomic
# (<file>.tmp.<pid>, then mv -f), so the file is never partial.
#
# Clock and time zone. Every function takes `now` from its caller;
# gaia_rate_limits_now honours GAIA_RATE_LIMITS_NOW (^[0-9]{1,12}$) so a test
# or a caller pins it. Local times follow the standard TZ variable.
#
# Sourcing defines constants and functions only and runs no external command,
# so it is safe in the statusline's hot path, under `set -u`, and with PATH
# empty. Bash 3.2 compatible, never `cd`s, and has no `set -e`. Each writer and
# reader call runs exactly one jq process. Double-sourcing is a no-op.

# shellcheck disable=SC2016 # jq programs are single-quoted on purpose

[ -n "${_GAIA_RATE_LIMITS_LIBRARY_LOADED:-}" ] && return 0
_GAIA_RATE_LIMITS_LIBRARY_LOADED=1

GAIA_RATE_LIMIT_WARNING_PERCENTAGE=75
GAIA_RATE_LIMIT_CRITICAL_PERCENTAGE=90
GAIA_RATE_LIMITS_FILE_VERSION=1
GAIA_RATE_LIMITS_SAME_WINDOW_SECONDS=600
GAIA_RATE_LIMITS_STALE_SECONDS=900
GAIA_RATE_LIMITS_REWRITE_SKIP_SECONDS=60
GAIA_RATE_LIMITS_HISTORY_LIMIT=48
GAIA_RATE_LIMITS_WINDOW_LIMIT=8
GAIA_RATE_LIMITS_BURN_SECONDS=3600
# The longest a window of each name can run: a reset later than now plus this
# (plus the same-window slack) is refused, and a reset earlier than now minus
# this is ignored.
GAIA_RATE_LIMITS_FIVE_HOUR_MAXIMUM_SECONDS=18000
GAIA_RATE_LIMITS_WINDOW_MAXIMUM_SECONDS=604800

_GAIA_RATE_LIMITS_RELATIVE_PATH=.gaia/local/cache/shared/rate-limits.json

# Definitions both jq programs share: the window name rule and the bounds a
# window must meet, in the writer and in every reader.
_GAIA_RATE_LIMITS_JQ_DEFINITIONS='
  def maximum_length($name): if $name == "five_hour" then $five_hour_maximum else $window_maximum end;
  def is_name: type == "string" and test("^[a-z0-9_]{1,32}$");
  def is_percentage: type == "number" and (isnan | not) and . >= 0 and . <= 999;
  def is_epoch: type == "number" and (isnan | not) and . == floor;
  def is_reset($name): is_epoch and . >= 1 and . <= ($now + maximum_length($name) + $same_window);
  def well_formed($name): ($name | is_name) and type == "object"
    and (.used_percentage | is_percentage) and (.resets_at | is_reset($name));
  def stored_valid($name): well_formed($name) and (.observed_at | is_epoch and . >= 0);
  def whole: (. + 0.5) | floor;
  def first_windows: to_entries | sort_by(.key) | .[:$window_limit];
'

# The writer: validate the input, read the stored file, merge, decide whether
# to rewrite, and emit "<status>", "<new file body or empty>", then the display
# records. Status is invalid, foreign (a version other than 1, left alone),
# unchanged (rewrite skipped) or write.
_GAIA_RATE_LIMITS_WRITE_PROGRAM='
  def record: "\(.key)\t\(.value.used_percentage | whole)\t\(.value.resets_at)\t\(if .value.resets_at <= $now then "reset" else "live" end)";
  def records: first_windows[] | record;
  def distance($a; $b): if $a > $b then $a - $b else $b - $a end;
  (try fromjson catch null) as $file
  | (if ($file | type) == "object" then $file else {} end) as $base
  | (($file | type) == "object" and ($file | has("version")) and $file.version != $version) as $foreign
  | (if ($foreign | not) and ($base.windows | type) == "object"
     then $base.windows | with_entries(select(.key as $name | .value | stored_valid($name)))
     else {} end) as $current
  | ($input | try fromjson catch null) as $reading
  | (if ($reading | type) == "object" and ($reading.windows | type) == "object"
     then $reading.windows | with_entries(select(.key as $name | .value | well_formed($name)))
     else {} end) as $input_windows
  | (($reading | type) == "object"
     and ($reading.producer == "statusline" or $reading.producer == "mod")
     and ($reading.windows | type) == "object"
     and ($reading.windows | length) >= 1
     and ($reading.windows | length) <= $window_limit
     and ($reading.windows | length) == ($input_windows | length)) as $valid
  | if ($valid | not) then
      "invalid", "",
      (reduce ($input_windows | to_entries[]) as $entry ($current;
        .[$entry.key] as $stored
        | if $stored == null then .[$entry.key] = $entry.value
          elif distance($entry.value.resets_at; $stored.resets_at) <= $same_window then
            .[$entry.key].used_percentage = ([$stored.used_percentage, $entry.value.used_percentage] | max)
            | .[$entry.key].resets_at = ([$stored.resets_at, $entry.value.resets_at] | max)
          else . end)
       | records)
    elif $foreign then
      "foreign", "", ($input_windows | records)
    else
      $reading.producer as $producer
      | (reduce ($input_windows | to_entries[] | select(.value.resets_at >= ($now - maximum_length(.key)))) as $entry ($current;
          $entry.key as $name
          | $entry.value as $incoming
          | .[$name] as $stored
          | {used_percentage: $incoming.used_percentage, observed_at: $now, producer: $producer} as $observation
          | if $stored == null or $incoming.resets_at > ($stored.resets_at + $same_window) then
              .[$name] = {used_percentage: $incoming.used_percentage, resets_at: $incoming.resets_at,
                          observed_at: $now, producer: $producer, history: [$observation]}
            elif $incoming.resets_at < ($stored.resets_at - $same_window) then .
            else
              ([$stored.resets_at, $incoming.resets_at] | max) as $resets_at
              | if $incoming.used_percentage > $stored.used_percentage then
                  .[$name] = ($stored + {used_percentage: $incoming.used_percentage, resets_at: $resets_at,
                    observed_at: $now, producer: $producer,
                    history: ((($stored.history | if type == "array" then . else [] end) + [$observation]) | .[-$history_limit:])})
                elif $incoming.used_percentage == $stored.used_percentage then
                  .[$name] = ($stored + {resets_at: $resets_at, observed_at: $now})
                else
                  .[$name] = ($stored + {resets_at: $resets_at})
                end
            end)) as $merged
      | ({version: $version} + $base | .version = $version | .windows = $merged) as $body
      | ($body | .windows |= with_entries(
          .key as $name
          | ($base.windows | if type == "object" then .[$name] else null end) as $previous
          | if ($previous | type) == "object" and ($previous.observed_at | type) == "number"
               and (.value.observed_at - $previous.observed_at) >= 0
               and (.value.observed_at - $previous.observed_at) < $rewrite_skip
            then .value.observed_at = $previous.observed_at else . end)) as $comparable
      | (if $comparable == $file then "unchanged", "" else "write", ($body | tojson) end),
        ($merged | records)
    end
'

# The reader: "ok" for a readable version-1 file, then the line records, the
# due records and, when a marker was given and anything is due, the merged
# marker body. Nothing at all for a file no reader may trust.
_GAIA_RATE_LIMITS_REPORT_PROGRAM='
  def clock($time): ($time | floor) as $seconds
    | if ($seconds | strflocaltime("%Y-%m-%d")) == ($now | strflocaltime("%Y-%m-%d"))
      then $seconds | strflocaltime("%H:%M") else $seconds | strflocaltime("%a %H:%M") end;
  def countdown($seconds): ((($seconds + 59) / 60) | floor) as $minutes
    | (($minutes / 1440) | floor) as $days | ((($minutes % 1440) / 60) | floor) as $hours
    | if $days > 0 then "\($days)d\($hours)h"
      elif $hours > 0 then "\($hours)h\($minutes % 60)m"
      else "\($minutes % 60)m" end;
  def age($seconds): (if $seconds > 0 then $seconds else 0 end) as $elapsed
    | (($elapsed / 60) | floor) as $minutes
    | if $elapsed >= 3600 then "\(($elapsed / 3600) | floor)h\($minutes % 60)m" else "\($minutes)m" end;
  def projection:
    [ (.history | if type == "array" then .[] else empty end)
      | select(type == "object" and (.used_percentage | is_percentage) and (.observed_at | is_epoch)
               and .observed_at >= ($now - $burn_seconds)) ] as $recent
    | if ($recent | length) < 2 then null
      else ($recent | min_by(.observed_at)) as $oldest | ($recent | max_by(.observed_at)) as $newest
        | if $newest.observed_at > $oldest.observed_at and $newest.used_percentage > $oldest.used_percentage
          then ((100 - .used_percentage) * ($newest.observed_at - $oldest.observed_at)
                / ($newest.used_percentage - $oldest.used_percentage)) as $remaining
            | $now + (if $remaining > 0 then ($remaining | ceil) else 0 end)
          else null end
      end;
  def band_rank: if . == "critical" then 2 elif . == "warning" then 1 else 0 end;
  def line:
    .key as $name | .value as $window | ($window.used_percentage | whole) as $percentage
    | if $window.resets_at <= $now then "\($name) reset"
      else ($window | projection) as $full_at
        | ($now - $window.observed_at) as $elapsed
        | "\($name) \($percentage)% resets \(clock($window.resets_at)) (in \(countdown($window.resets_at - $now))) projected "
          + (if $full_at == null then "unknown"
             else "100% at \(clock($full_at))" + (if $full_at > $window.resets_at then " after reset" else "" end) end)
          + " as of \(age($elapsed)) ago" + (if $elapsed > $stale_seconds then " stale" else "" end)
      end;
  (try fromjson catch null) as $file
  | if ($file | type) == "object" and $file.version == $version and ($file.windows | type) == "object" then
      ($file.windows | with_entries(select(.key as $name | .value | stored_valid($name))) | first_windows) as $windows
      | ($marker | try fromjson catch null | if type == "object" then . else {} end) as $marker_entries
      | [ $windows[]
          | select($has_marker)
          | .key as $name | .value as $window | ($window.used_percentage | whole) as $percentage
          | select($window.resets_at > $now and $percentage >= $warning)
          | (if $percentage >= $critical then "critical" else "warning" end) as $band
          | ($marker_entries[$name]) as $told
          | (if ($told | type) == "object" and ($told.resets_at | type) == "number"
                and (($told.resets_at - $window.resets_at) | if . < 0 then -. else . end) <= $same_window
             then ($told.band | band_rank) else 0 end) as $told_rank
          | select(($band | band_rank) > $told_rank)
          | {name: $name, band: $band, percentage: $percentage, resets_at: $window.resets_at} ] as $due
      | "ok",
        ($windows[] | "line\t\(line)"),
        ($due[] | "due\t\(.name)\t\(.band)\t\(.percentage)\t\(clock(.resets_at))\t\(.resets_at)"),
        (if ($due | length) > 0
         then "marker\t\($marker_entries + ($due | map({(.name): {resets_at: .resets_at, band: .band}}) | add) | tojson)"
         else empty end)
    else empty end
'

# gaia_rate_limits_file <main-root>: print the shared file path.
gaia_rate_limits_file() {
  printf '%s/%s\n' "${1:-}" "$_GAIA_RATE_LIMITS_RELATIVE_PATH"
}

# gaia_rate_limits_now: print the epoch seconds to use. GAIA_RATE_LIMITS_NOW
# when it is 1-12 digits, else EPOCHSECONDS (bash 5), else `date +%s`; rc 1
# when none yields an integer.
gaia_rate_limits_now() {
  local pattern='^[0-9]{1,12}$' value
  if [[ ${GAIA_RATE_LIMITS_NOW:-} =~ $pattern ]]; then
    printf '%s\n' "$((10#$GAIA_RATE_LIMITS_NOW))"
    return 0
  fi
  if [[ ${EPOCHSECONDS:-} =~ $pattern ]]; then
    printf '%s\n' "$EPOCHSECONDS"
    return 0
  fi
  value=$(date +%s 2>/dev/null) || value=""
  [[ $value =~ $pattern ]] || return 1
  printf '%s\n' "$value"
}

# gaia_rate_limits_band <whole-percentage>: green, warning or critical, by the
# same at-or-past comparisons the statusline draws. rc 2 on a non-integer.
gaia_rate_limits_band() {
  local pattern='^[0-9]{1,12}$'
  [[ ${1:-} =~ $pattern ]] || return 2
  if [ "$((10#$1))" -ge "$GAIA_RATE_LIMIT_CRITICAL_PERCENTAGE" ]; then
    printf 'critical\n'
  elif [ "$((10#$1))" -ge "$GAIA_RATE_LIMIT_WARNING_PERCENTAGE" ]; then
    printf 'warning\n'
  else
    printf 'green\n'
  fi
}

# gaia_rate_limits_is_window_name <name>: rc 0 for 1-32 lowercase letters,
# digits and underscores. Builtins only.
gaia_rate_limits_is_window_name() {
  local pattern='^[a-z0-9_]{1,32}$'
  [[ ${1:-} =~ $pattern ]]
}

# _gaia_rate_limits_jq <now> <program> [jq arguments...]: run the one jq call
# with every constant bound, reading stdin raw. LC_ALL=C keeps weekday names
# English whatever the locale.
_gaia_rate_limits_jq() {
  local now="$1" program="$2"
  shift 2
  LC_ALL=C jq -rRs \
    --argjson now "$now" \
    --argjson version "$GAIA_RATE_LIMITS_FILE_VERSION" \
    --argjson same_window "$GAIA_RATE_LIMITS_SAME_WINDOW_SECONDS" \
    --argjson stale_seconds "$GAIA_RATE_LIMITS_STALE_SECONDS" \
    --argjson rewrite_skip "$GAIA_RATE_LIMITS_REWRITE_SKIP_SECONDS" \
    --argjson history_limit "$GAIA_RATE_LIMITS_HISTORY_LIMIT" \
    --argjson window_limit "$GAIA_RATE_LIMITS_WINDOW_LIMIT" \
    --argjson burn_seconds "$GAIA_RATE_LIMITS_BURN_SECONDS" \
    --argjson five_hour_maximum "$GAIA_RATE_LIMITS_FIVE_HOUR_MAXIMUM_SECONDS" \
    --argjson window_maximum "$GAIA_RATE_LIMITS_WINDOW_MAXIMUM_SECONDS" \
    --argjson warning "$GAIA_RATE_LIMIT_WARNING_PERCENTAGE" \
    --argjson critical "$GAIA_RATE_LIMIT_CRITICAL_PERCENTAGE" \
    "$@" "$_GAIA_RATE_LIMITS_JQ_DEFINITIONS $program"
}

# gaia_rate_limits_write <main-root> <now> <input-json>: the one writer.
# rc 0 accepted (written, rewrite skipped, or a stored version other than 1
# left alone); rc 2 invalid reading (stderr exactly `rate-limits: invalid
# reading`, file untouched); rc 1 the write failed (no temporary file left;
# also a bad `now` or no jq, with no output). Stdout on every rc: one display
# record per window, sorted by name, at most GAIA_RATE_LIMITS_WINDOW_LIMIT:
#   <name><TAB><whole percentage><TAB><resets_at><TAB><live|reset>
# On rc 0 and rc 1 the records are the merged result, so a failed write still
# shows the higher of file and input. On rc 2 they are the file's valid
# windows, each raised by a well-formed same-window input window, plus each
# well-formed input window the file lacks. With a foreign version they are the
# input's well-formed windows. Never prints to stderr except on rc 2.
gaia_rate_limits_write() {
  local root="${1:-}" now="${2:-}" input="${3:-}" pattern='^[0-9]{1,12}$'
  local file source output status body records="" directory temporary_file
  [[ $now =~ $pattern ]] || return 1
  now=$((10#$now))
  command -v jq >/dev/null 2>&1 || return 1
  file="$root/$_GAIA_RATE_LIMITS_RELATIVE_PATH"
  source=/dev/null
  [ -f "$file" ] && [ -r "$file" ] && source="$file"
  output=$(_gaia_rate_limits_jq "$now" "$_GAIA_RATE_LIMITS_WRITE_PROGRAM" --arg input "$input" 2>/dev/null <"$source") || return 1
  status="${output%%$'\n'*}"
  case $output in
    *$'\n'*) output="${output#*$'\n'}" ;;
    *) output="" ;;
  esac
  body="${output%%$'\n'*}"
  case $output in
    *$'\n'*) records="${output#*$'\n'}" ;;
  esac
  case $status in
    invalid)
      [ -n "$records" ] && printf '%s\n' "$records"
      printf 'rate-limits: invalid reading\n' >&2
      return 2
      ;;
    foreign | unchanged)
      [ -n "$records" ] && printf '%s\n' "$records"
      return 0
      ;;
    write) ;;
    *) return 1 ;;
  esac
  [ -n "$records" ] && printf '%s\n' "$records"
  directory="${file%/*}"
  mkdir -p "$directory" 2>/dev/null || return 1
  temporary_file="$file.tmp.$$"
  printf '%s\n' "$body" 2>/dev/null >"$temporary_file" || {
    rm -f "$temporary_file" 2>/dev/null
    return 1
  }
  mv -f "$temporary_file" "$file" 2>/dev/null || {
    rm -f "$temporary_file" 2>/dev/null
    return 1
  }
  return 0
}

# gaia_rate_limits_report <main-root> <now> [<marker-file>]: the one reader.
# Stdout, windows sorted by name, the first GAIA_RATE_LIMITS_WINDOW_LIMIT
# valid ones only:
#   line<TAB><reader line>
#   due<TAB><name><TAB><warning|critical><TAB><whole percentage><TAB><resets label><TAB><resets_at>
#   marker<TAB><compact JSON marker body>
# `due` and `marker` only when a marker-file argument is given (a missing or
# unparseable marker counts as empty): a window is due when it is unexpired, at
# or above the warning band, and above the band the marker holds for the same
# window (its resets_at within GAIA_RATE_LIMITS_SAME_WINDOW_SECONDS). `marker`
# comes last, at most once, only with a due record: the marker's entries with
# each due window set to {"resets_at":<epoch>,"band":"<band>"}.
# Reader line:
#   <name> <P>% resets <when> (in <countdown>) projected <100% at <when>[ after reset]|unknown> as of <age> ago[ stale]
#   <name> reset
# <when> is HH:MM on today's local date, else `Ddd HH:MM`. The projection is
# the slope from the oldest history entry observed within the last
# GAIA_RATE_LIMITS_BURN_SECONDS to the newest, carried forward from now.
# rc 0 with records; rc 0 and no output when the file holds no valid window;
# rc 1 and no output for a missing, unparseable or foreign-version file, a bad
# `now`, or no jq.
gaia_rate_limits_report() {
  local root="${1:-}" now="${2:-}" pattern='^[0-9]{1,12}$' file output has_marker=false
  local -a marker_arguments
  [[ $now =~ $pattern ]] || return 1
  now=$((10#$now))
  file="$root/$_GAIA_RATE_LIMITS_RELATIVE_PATH"
  [ -f "$file" ] && [ -r "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  marker_arguments=(--arg marker "")
  if [ $# -ge 3 ]; then
    has_marker=true
    [ -f "$3" ] && [ -r "$3" ] && marker_arguments=(--rawfile marker "$3")
  fi
  output=$(_gaia_rate_limits_jq "$now" "$_GAIA_RATE_LIMITS_REPORT_PROGRAM" \
    --argjson has_marker "$has_marker" ${marker_arguments[@]+"${marker_arguments[@]}"} 2>/dev/null <"$file") || return 1
  case $output in
    ok) return 0 ;;
    ok$'\n'*) printf '%s\n' "${output#ok$'\n'}" ;;
    *) return 1 ;;
  esac
}
