# shellcheck shell=bash
#
# The jq program text of the rate-limit reading library. Only shell variables,
# assigned at source time with no command run; rate-limits-lib.sh sources this
# file and owns every constant, band value and function the programs rely on.
# The rules these programs implement are stated in that library's header.
#
# Every program reads stdin raw and slurped (`jq -rRs`): the session's own
# reading file, or nothing. Other sessions' files arrive as `--rawfile
# reading_<index>` with their session ids, newest first, as the positional
# arguments, so each one is parsed on its own and an unparseable file hides no
# other.

# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# shellcheck disable=SC2034 # read by rate-limits-lib.sh, which sources this file

[ -n "${_GAIA_RATE_LIMITS_PROGRAMS_LOADED:-}" ] && return 0
_GAIA_RATE_LIMITS_PROGRAMS_LOADED=1

# Definitions both programs share: the stored windows, the validity rule of a
# stored entry, the scan of other sessions' files and the latest-change choice.
_GAIA_RATE_LIMITS_JQ_DEFINITIONS='
  def window_names: ["five_hour", "seven_day"];
  def maximum_length($name): if $name == "five_hour" then $five_hour_maximum else $window_maximum end;
  def is_number: type == "number" and (isnan | not);
  def is_percentage: is_number and . >= 0 and . <= 999;
  def is_epoch: is_number and . == floor;
  def is_reset($name): is_epoch and . >= 1 and . <= ($now + maximum_length($name) + $same_window);
  def distance($a; $b): if $a > $b then $a - $b else $b - $a end;
  def whole: (. + 0.5) | floor;
  def valid_entry($name): type == "object"
    and (.used_percentage | is_percentage) and (.resets_at | is_reset($name))
    and (.changed_at | is_epoch and . >= 0 and . <= ($now + $future_skew))
    and (.confirmed | type == "boolean");
  def reading_windows: (try fromjson catch null) as $file
    | if ($file | type) == "object" and $file.version == $version and ($file.windows | type) == "object"
      then [ window_names[] as $name | $file.windows[$name] | select(valid_entry($name)) | {key: $name, value: .} ]
        | from_entries
      else null end;
  def scanned: [ $ARGS.positional | to_entries[]
    | {session: .value, windows: ($ARGS.named["reading_\(.key)"] | reading_windows)}
    | select(.windows != null) ];
  def rank: [ (if .value.resets_at > $now then 0 else 1 end), (if .value.confirmed then 0 else 1 end),
    (if .value.confirmed then 0 - .value.changed_at else .value.changed_at end), .session ];
  def latest($candidates; $name):
    [ $candidates[] | .session as $session | .windows[$name] | select(. != null) | {session: $session, value: .} ]
    | sort_by(rank) | if length > 0 then .[0].value else null end;
'

# The writer: validate the payload, apply the writer rules to the own file's
# windows, and emit "<status>", "<new file body or empty>", then the display
# records, each the latest-change choice with the own file as written. Status
# is invalid, unchanged or write. The new body depends on the own file, the
# payload and the clock alone; other sessions' files feed only the display.
_GAIA_RATE_LIMITS_WRITE_PROGRAM='
  def record($name): "\($name)\t\(.used_percentage | whole)\t\(.resets_at)\t\(if .resets_at <= $now then "reset" else "live" end)";
  def display($candidates): window_names[] as $name | latest($candidates; $name) | select(. != null) | record($name);
  (reading_windows // {}) as $current
  | ($input | try fromjson catch null) as $reading
  | (($reading | type) == "object" and ($reading.windows | type) == "object"
     and all(window_names[]; . as $name | $reading.windows[$name]
       | . == null or (type == "object" and (.used_percentage | is_percentage)
                       and (.resets_at | . == null or is_reset($name))))) as $valid
  | scanned as $others
  | if ($valid | not) then
      "invalid", "", display([ $others[] | if .session == $own then .windows = $current else . end ])
    else
      (reduce (window_names[] as $name | $reading.windows[$name] | select(. != null) | {name: $name, value: .}) as $entry ($current;
        $entry.name as $name | $entry.value as $incoming | .[$name] as $stored
        | ($incoming.resets_at // ($stored | if . == null then null else .resets_at end)) as $resets_at
        | {used_percentage: $incoming.used_percentage, changed_at: $now} as $change
        | {used_percentage: $incoming.used_percentage, resets_at: $resets_at, changed_at: $now,
           confirmed: true, history: [$change]} as $fresh
        | if $resets_at == null or $resets_at < ($now - maximum_length($name)) then .
          elif $stored == null then .[$name] = ($fresh | .confirmed = false)
          elif distance($resets_at; $stored.resets_at) > $same_window then .[$name] = $fresh
          elif $incoming.used_percentage == $stored.used_percentage then .
          else .[$name] = ($stored + {used_percentage: $incoming.used_percentage, resets_at: $resets_at,
              changed_at: $now, confirmed: true,
              history: ((($stored.history | if type == "array" then . else [] end) + [$change]) | .[-$history_limit:])})
          end)) as $windows
      | ($windows != $current) as $changed
      | (if any($others[]; .session == $own) then [ $others[] | if .session == $own then .windows = $windows else . end ]
         elif $changed then ([{session: $own, windows: $windows}] + $others) | .[:$scan_limit]
         else $others end) as $candidates
      | (if $changed then "write", ({version: $version, windows: $windows} | tojson) else "unchanged", "" end),
        display($candidates)
    end
'

# The reader: "ok<TAB><0|1>" (1 when the chosen 7-day figure needs the tier),
# then, per band set index the caller may pick, "<index><TAB><record>": the
# line records, and with a marker the due records and the marker body. Nothing
# at all in own mode when the own file is missing, unparseable or not version 2.
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
      | select(type == "object" and (.used_percentage | is_percentage) and (.changed_at | is_epoch)
               and .changed_at >= ($now - $burn_seconds)) ] as $recent
    | if ($recent | length) < 2 then null
      else ($recent | min_by(.changed_at)) as $oldest | ($recent | max_by(.changed_at)) as $newest
        | if $newest.changed_at > $oldest.changed_at and $newest.used_percentage > $oldest.used_percentage
          then ((100 - .used_percentage) * ($newest.changed_at - $oldest.changed_at)
                / ($newest.used_percentage - $oldest.used_percentage)) as $remaining
            | $now + (if $remaining > 0 then ($remaining | ceil) else 0 end)
          else null end
      end;
  def band_rank: if . == "critical" then 2 elif . == "warning" then 1 else 0 end;
  def band($percentage; $set):
    if $percentage >= $set[1] then "critical" elif $percentage >= $set[0] then "warning" else "clear" end;
  def line: .name as $name | .value as $window
    | if $window.resets_at <= $now then "\($name) reset"
      else ($window | projection) as $full_at
        | "\($name) \(.percentage)%" + (if .band == "clear" then "" else " \(.band)" end)
          + " resets \(clock($window.resets_at)) (in \(countdown($window.resets_at - $now))) projected "
          + (if $full_at == null then "unknown"
             else "100% at \(clock($full_at))" + (if $full_at > $window.resets_at then " after reset" else "" end) end)
          + " changed \(age($now - $window.changed_at)) ago" + (if $window.confirmed then "" else " unconfirmed" end)
      end;
  reading_windows as $own_windows
  | if $mode == "own" and $own_windows == null then empty
    else
      ($own_windows // {}) as $own_entries
      | (if $mode == "own" or $own_windows != null then $own_entries
         else scanned as $others
           | [ window_names[] as $name | latest($others; $name)
               | select(. != null) | {key: $name, value: .} ] | from_entries end) as $chosen
      | ($sets | map(.[0]) | min) as $lowest_warning
      | ($chosen.seven_day | . != null and .resets_at > $now and (.used_percentage | whole) >= $lowest_warning) as $needs_tier
      | ($marker | try fromjson catch null | if type == "object" then . else {} end) as $marker_entries
      | "ok\t\(if $needs_tier then 1 else 0 end)",
        ((if $needs_tier then range(0; $sets | length) else 0 end) as $set_index
         | [ $chosen | to_entries[] | (.value.used_percentage | whole) as $percentage
             | {name: .key, value: .value, percentage: $percentage,
                band: band($percentage; if .key == "seven_day" then $sets[$set_index] else $sets[0] end)} ] as $rows
         | [ $rows[] | select($has_marker and .value.resets_at > $now)
             | $marker_entries[.name] as $told
             | . + {rank: (.band | band_rank),
                    told_rank: (if ($told | type) == "object" and ($told.resets_at | is_number)
                                   and distance($told.resets_at; .value.resets_at) <= $same_window
                                then ($told.band | band_rank) else 0 end)} ] as $judged
         | ($marker_entries + ([ $judged[] | select(.rank != .told_rank)
             | {(.name): {resets_at: .value.resets_at, band: .band}} ] | add // {})) as $new_marker
         | "\($set_index)\t" + (
             ($rows[] | "line\t\(line)"),
             ($judged[] | select(.rank > .told_rank)
               | "due\t\(.name)\t\(.band)\t\(.percentage)\t\(clock(.value.resets_at))\t\(.value.resets_at)"),
             (if $has_marker and $new_marker != $marker_entries then "marker\t\($new_marker | tojson)" else empty end)))
    end
'
