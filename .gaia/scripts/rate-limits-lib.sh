# shellcheck shell=bash
#
# Rate-limit reading lib. The ONE place the account's 5-hour and 7-day usage
# windows are stored per session, chosen across sessions and rendered as text,
# and the ONE definition of the warning and critical bands, the 7-day band sets
# and the tier map the statusline and the dispatch checkpoint both use.
#
# Owns: one reading file per session (<main>/.gaia/local/cache/shared/rate-limits/<session_id>.json,
# reached from every linked worktree, only for a UUID-shaped id), its one
# writer (gaia_rate_limits_write), its one reader (gaia_rate_limits_report:
# reader lines, due bands, the marker body), the latest-change choice, the
# bands, the tier map and the clock override.
# Does not own: turning a statusline payload into a reading (the statusline
# does that and calls the writer), drawing the usage segments, the dispatch
# checkpoint's marker file (its hook writes the body this lib computes), or
# the policy for acting on a reading. The jq program text lives in
# rate-limits-programs-lib.sh, sourced from this file's folder.
#
# Input and stored shape. The writer takes
#   {"windows":{"five_hour":{"used_percentage":80,"resets_at":1795449600},"seven_day":{"used_percentage":40}}}
# (resets_at may be absent; any other key or window name is ignored) and stores
#   {"version":2,"windows":{"five_hour":{"used_percentage":80,"resets_at":1795449600,
#     "changed_at":1795440000,"confirmed":true,"history":[{"used_percentage":80,"changed_at":1795440000}]}}}
# History holds changes only, the newest GAIA_RATE_LIMITS_HISTORY_LIMIT.
#
# Writer rules per window, on the session's own file alone:
#   - first reading of the window: stored with confirmed false, changed_at now;
#   - a reset time more than GAIA_RATE_LIMITS_SAME_WINDOW_SECONDS away, earlier
#     or later (a new window or another account): the window, history
#     included, is replaced, confirmed true, changed_at now;
#   - same window, a different figure, in either direction: the figure and the
#     incoming reset time replace the stored ones, one history entry is
#     appended, confirmed true, changed_at now;
#   - same window, equal figure: nothing is rewritten, reset drift included,
#     so a file's modification time moves only on a change;
#   - no reset time: stored against the stored reset time, else nothing.
# A session's figures are account-wide and change only when it receives a new
# API response, so an idle session repeating an old figure never moves its file.
#
# Latest-change choice, per window, over the GAIA_RATE_LIMITS_SCAN_LIMIT most
# recently modified UUID-named regular files, each parsed on its own. An entry
# counts only when its file is version 2, its figure a number in 0..999, its
# changed_at an integer from 0 to now plus GAIA_RATE_LIMITS_FUTURE_SKEW_SECONDS
# and its confirmed a boolean. Ranking: unexpired over expired, confirmed over
# unconfirmed, newest changed_at among confirmed, oldest among unconfirmed (a
# new session's first figure may predate its first response, so it never
# displaces a confirmed one), then the lower session id. The statusline always shows this choice.
# The reader shows only the session's own windows once its file is valid: the
# file holds every window its account reports, and another session's file may
# belong to another account sharing this cache (a second profile), so a
# window the own file lacks is one this account does not have.
#
# Bands. The 5-hour window uses the standard set on every tier: warning late
# costs a limit hit mid-task, warning early costs one question. The 7-day
# window uses the account tier's set, compared on the whole (rounded) figure.
# The tier is read only when the chosen whole 7-day figure reaches the lowest
# 7-day warning of any set, so the large account profile is never opened on
# the statusline's path, and only one string key is extracted from it. Band-set
# names stay internal; only the band word reaches output.
#
# Reader line:
#   <name> <P>%[ <warning|critical>] resets <when> (in <countdown>) projected <100% at <when>[ after reset]|unknown> changed <age> ago[ unconfirmed]
#   <name> reset
# <when> is HH:MM on today's local date, else `Ddd HH:MM`; <age> is <m>m, or
# past an hour <h>h<m>m. The projection is the slope from the oldest history
# entry changed within the last GAIA_RATE_LIMITS_BURN_SECONDS to the newest,
# carried forward from now, on the chosen entry's own history only.
#
# No lock: each file has one writer, the session that owns it, and each write
# is atomic (<file>.tmp.<pid>, then mv -f), so a file is never partial.
#
# Clock and time zone. Every function takes `now` from its caller;
# gaia_rate_limits_now honours GAIA_RATE_LIMITS_NOW (^[0-9]{1,12}$) so a test
# or a caller pins it. Local times follow the standard TZ variable.
#
# Sourcing defines constants and functions only and runs no external command,
# so it is safe in the statusline's hot path, under `set -u`, and with PATH
# empty. Bash 3.2 compatible, never `cd`s, and has no `set -e`. A writer call
# runs exactly one jq process; a report call at most two, the report program
# and, only past the tier threshold, the profile read. Double-sourcing is a
# no-op. When a sibling lib cannot be sourced, every session-keyed function
# returns 1 with no output, so every caller fails open.

[ -n "${_GAIA_RATE_LIMITS_LIBRARY_LOADED:-}" ] && return 0
_GAIA_RATE_LIMITS_LIBRARY_LOADED=1

# Standard set: the 5-hour window on every tier, the 7-day window on an
# unmapped tier, and the statusline colors.
GAIA_RATE_LIMIT_WARNING_PERCENTAGE=75
GAIA_RATE_LIMIT_CRITICAL_PERCENTAGE=90
# 7-day sets of the larger plans, starting estimates ordered by plan size.
GAIA_RATE_LIMIT_MAX_WARNING_PERCENTAGE=80
GAIA_RATE_LIMIT_MAX_CRITICAL_PERCENTAGE=92
GAIA_RATE_LIMIT_ULTRA_WARNING_PERCENTAGE=85
GAIA_RATE_LIMIT_ULTRA_CRITICAL_PERCENTAGE=95
GAIA_RATE_LIMITS_FILE_VERSION=2
GAIA_RATE_LIMITS_SAME_WINDOW_SECONDS=600
GAIA_RATE_LIMITS_HISTORY_LIMIT=48
GAIA_RATE_LIMITS_BURN_SECONDS=3600
# Bounds the files one render or reader parses; idle sessions' files are the
# oldest and drop out first.
GAIA_RATE_LIMITS_SCAN_LIMIT=32
# The writer (statusline) and readers are separate processes whose clocks may
# differ slightly; a changed_at further ahead than this is forged or broken.
GAIA_RATE_LIMITS_FUTURE_SKEW_SECONDS=60
# The longest a window of each name can run: a reset later than now plus this
# (plus the same-window slack) is refused, and a reset earlier than now minus
# this is ignored.
GAIA_RATE_LIMITS_FIVE_HOUR_MAXIMUM_SECONDS=18000
GAIA_RATE_LIMITS_WINDOW_MAXIMUM_SECONDS=604800

# The checkpoint hook's fast pre-check text-parses this line: keep it NAME=value.
_GAIA_RATE_LIMITS_RELATIVE_PATH=.gaia/local/cache/shared/rate-limits

_gaia_rate_limits_library_directory="${BASH_SOURCE[0]%/*}"
[ "$_gaia_rate_limits_library_directory" = "${BASH_SOURCE[0]}" ] && _gaia_rate_limits_library_directory=.
_GAIA_RATE_LIMITS_SIBLINGS_LOADED=""
# shellcheck source=.gaia/scripts/context-checkpoint-lib.sh
if . "$_gaia_rate_limits_library_directory/context-checkpoint-lib.sh" 2>/dev/null \
  && command -v gaia_context_is_session_id >/dev/null 2>&1; then
  # shellcheck source=.gaia/scripts/rate-limits-programs-lib.sh
  . "$_gaia_rate_limits_library_directory/rate-limits-programs-lib.sh" 2>/dev/null \
    && [ -n "${_GAIA_RATE_LIMITS_REPORT_PROGRAM:-}" ] && _GAIA_RATE_LIMITS_SIBLINGS_LOADED=1
fi

# gaia_rate_limits_file <main-root> <session-id>: print the session's reading
# file; rc 1 and no output for an id that is not UUID-shaped.
gaia_rate_limits_file() {
  [ -n "$_GAIA_RATE_LIMITS_SIBLINGS_LOADED" ] || return 1
  gaia_context_is_session_id "${2:-}" || return 1
  printf '%s/%s/%s.json\n' "${1:-}" "$_GAIA_RATE_LIMITS_RELATIVE_PATH" "$2"
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

# gaia_rate_limits_is_window_name <name>: rc 0 for 1-32 lowercase letters,
# digits and underscores. Builtins only.
gaia_rate_limits_is_window_name() {
  local pattern='^[a-z0-9_]{1,32}$'
  [[ ${1:-} =~ $pattern ]]
}

# gaia_rate_limits_seven_day_set: set _GAIA_RATE_LIMITS_SEVEN_DAY_SET_INDEX to
# the index in the jq `sets` array of the account tier's 7-day band set (0
# standard, 1 max, 2 ultra), never printed.
# The profile is $CLAUDE_CONFIG_DIR/.claude.json when that variable is set and
# non-empty, with no fallback, else $HOME/.claude.json. Exactly one jq that
# emits only a string value of the one key, its stderr discarded, so no other
# profile field can reach output; anything unreadable or unmapped is standard,
# so a guess never loosens a band. Only tier strings read off real profiles
# are mapped.
gaia_rate_limits_seven_day_set() {
  local profile tier=""
  _GAIA_RATE_LIMITS_SEVEN_DAY_SET_INDEX=0
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    profile="$CLAUDE_CONFIG_DIR/.claude.json"
  elif [ -n "${HOME:-}" ]; then
    profile="$HOME/.claude.json"
  else
    return 0
  fi
  [ -f "$profile" ] && [ -r "$profile" ] || return 0
  tier=$(jq -r 'try (.oauthAccount.organizationRateLimitTier | strings) // empty' "$profile" 2>/dev/null) || tier=""
  case $tier in
    default_claude_max_20x) _GAIA_RATE_LIMITS_SEVEN_DAY_SET_INDEX=2 ;;
    default_claude_max_5x) _GAIA_RATE_LIMITS_SEVEN_DAY_SET_INDEX=1 ;;
    # default_raven, and anything unmapped, stays standard.
  esac
  return 0
}

# _gaia_rate_limits_scan <directory>: set
# _GAIA_RATE_LIMITS_SCANNED to the newest GAIA_RATE_LIMITS_SCAN_LIMIT
# UUID-named regular readable files, newest first. Builtins only: `-nt`
# compares modification times, so no `ls` or `stat` runs on the render path.
_gaia_rate_limits_scan() {
  local path name index count
  _GAIA_RATE_LIMITS_SCANNED=()
  for path in "${1:-}"/*.json; do
    [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || continue
    name="${path##*/}"
    gaia_context_is_session_id "${name%.json}" || continue
    count=${#_GAIA_RATE_LIMITS_SCANNED[@]}
    index=$count
    while [ "$index" -gt 0 ] && [ "$path" -nt "${_GAIA_RATE_LIMITS_SCANNED[index - 1]}" ]; do
      _GAIA_RATE_LIMITS_SCANNED[index]="${_GAIA_RATE_LIMITS_SCANNED[index - 1]}"
      index=$((index - 1))
    done
    _GAIA_RATE_LIMITS_SCANNED[index]="$path"
    [ "$count" -lt "$GAIA_RATE_LIMITS_SCAN_LIMIT" ] || unset "_GAIA_RATE_LIMITS_SCANNED[$count]"
  done
}

# _gaia_rate_limits_jq <now> <program> [jq options...]: run one jq call with
# every constant bound, reading stdin raw, and the scanned files as
# reading_<index> with their session ids positional. LC_ALL=C keeps weekday
# names English whatever the locale.
_gaia_rate_limits_jq() {
  local now="$1" program="$2" index=0 path name
  local -a files=() sessions=()
  shift 2
  for path in ${_GAIA_RATE_LIMITS_SCANNED[@]+"${_GAIA_RATE_LIMITS_SCANNED[@]}"}; do
    name="${path##*/}"
    files+=(--rawfile "reading_$index" "$path")
    sessions+=("${name%.json}")
    index=$((index + 1))
  done
  LC_ALL=C jq -rRs \
    --argjson now "$now" \
    --argjson version "$GAIA_RATE_LIMITS_FILE_VERSION" \
    --argjson same_window "$GAIA_RATE_LIMITS_SAME_WINDOW_SECONDS" \
    --argjson history_limit "$GAIA_RATE_LIMITS_HISTORY_LIMIT" \
    --argjson burn_seconds "$GAIA_RATE_LIMITS_BURN_SECONDS" \
    --argjson scan_limit "$GAIA_RATE_LIMITS_SCAN_LIMIT" \
    --argjson future_skew "$GAIA_RATE_LIMITS_FUTURE_SKEW_SECONDS" \
    --argjson five_hour_maximum "$GAIA_RATE_LIMITS_FIVE_HOUR_MAXIMUM_SECONDS" \
    --argjson window_maximum "$GAIA_RATE_LIMITS_WINDOW_MAXIMUM_SECONDS" \
    --argjson sets "[[$GAIA_RATE_LIMIT_WARNING_PERCENTAGE,$GAIA_RATE_LIMIT_CRITICAL_PERCENTAGE],[$GAIA_RATE_LIMIT_MAX_WARNING_PERCENTAGE,$GAIA_RATE_LIMIT_MAX_CRITICAL_PERCENTAGE],[$GAIA_RATE_LIMIT_ULTRA_WARNING_PERCENTAGE,$GAIA_RATE_LIMIT_ULTRA_CRITICAL_PERCENTAGE]]" \
    ${files[@]+"${files[@]}"} "$@" \
    "$_GAIA_RATE_LIMITS_JQ_DEFINITIONS $program" --args ${sessions[@]+"${sessions[@]}"}
}

# gaia_rate_limits_write <main-root> <now> <session-id> <input-json>: the one
# writer, used by the statusline and the CLI's write verb. rc 0 written or
# unchanged; rc 2 invalid input (stderr exactly `rate-limits: invalid
# reading`, the file untouched); rc 1 the write failed, a bad `now`, no jq or
# a session id that is not UUID-shaped (the last three with no output and
# nothing created). Stdout on rc 0, 1 and 2: at most one display record per
# window, five_hour before seven_day, each the latest-change choice after this
# write:
#   <name><TAB><whole percentage><TAB><resets_at><TAB><live|reset>
gaia_rate_limits_write() {
  local root="${1:-}" now="${2:-}" session_id="${3:-}" input="${4:-}" pattern='^[0-9]{1,12}$'
  local directory file source output status body records="" temporary_file
  [ -n "$_GAIA_RATE_LIMITS_SIBLINGS_LOADED" ] || return 1
  [[ $now =~ $pattern ]] || return 1
  now=$((10#$now))
  gaia_context_is_session_id "$session_id" || return 1
  command -v jq >/dev/null 2>&1 || return 1
  directory="$root/$_GAIA_RATE_LIMITS_RELATIVE_PATH"
  file="$directory/$session_id.json"
  source=/dev/null
  [ -f "$file" ] && [ -r "$file" ] && source="$file"
  _gaia_rate_limits_scan "$directory"
  output=$(_gaia_rate_limits_jq "$now" "$_GAIA_RATE_LIMITS_WRITE_PROGRAM" \
    --arg input "$input" --arg own "$session_id" 2>/dev/null <"$source") || return 1
  status="${output%%$'\n'*}"
  case $output in
    *$'\n'*) output="${output#*$'\n'}" ;;
    *) output="" ;;
  esac
  body="${output%%$'\n'*}"
  case $output in
    *$'\n'*) records="${output#*$'\n'}" ;;
  esac
  [ -z "$records" ] || printf '%s\n' "$records"
  case $status in
    invalid)
      printf 'rate-limits: invalid reading\n' >&2
      return 2
      ;;
    unchanged) return 0 ;;
    write) ;;
    *) return 1 ;;
  esac
  [ -d "$directory" ] || mkdir -p "$directory" 2>/dev/null || return 1
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

# gaia_rate_limits_report <main-root> <now> <own|reader> <session-id> [<marker-file>]:
# the one reader, used by the CLI (reader) and the dispatch hook (own, with
# its marker file). `own` reads only the session's own file: rc 1 and no
# output when the id is not UUID-shaped or the file is missing, unreadable,
# unparseable or not version 2. `reader` takes the own file's valid entries
# alone when the id is UUID-shaped and that file is valid, else the
# latest-change choice per window. Stdout, windows sorted by name:
#   line<TAB><reader line>
#   due<TAB><name><TAB><warning|critical><TAB><whole percentage><TAB><resets label><TAB><resets_at>
#   marker<TAB><compact JSON marker body>
# `due` and `marker` only with a marker-file argument (a missing or
# unparseable marker counts as empty). A window is due when it is unexpired
# and its band is above the band the marker holds for it, a marker entry
# counting only when its resets_at is within the same-window slack (a new
# window starts from clear). `marker` comes last, at most once, only when the
# body changes: each due window raised to its band, each window whose band
# fell below the marked one lowered to the new band (clear included), so the
# next climb speaks again; other entries are kept. rc 0 with records; rc 0 and
# no output when no window is chosen; rc 1 and no output on a bad `now`, no jq
# or any failure.
gaia_rate_limits_report() {
  local root="${1:-}" now="${2:-}" mode="${3:-}" session_id="${4:-}" pattern='^[0-9]{1,12}$'
  local directory file source=/dev/null output first set_index=0 has_marker=false record tab=$'\t'
  local -a marker_arguments
  [ -n "$_GAIA_RATE_LIMITS_SIBLINGS_LOADED" ] || return 1
  [[ $now =~ $pattern ]] || return 1
  now=$((10#$now))
  command -v jq >/dev/null 2>&1 || return 1
  directory="$root/$_GAIA_RATE_LIMITS_RELATIVE_PATH"
  file=""
  gaia_context_is_session_id "$session_id" && file="$directory/$session_id.json"
  _GAIA_RATE_LIMITS_SCANNED=()
  case $mode in
    own)
      [ -n "$file" ] && [ -f "$file" ] && [ -r "$file" ] || return 1
      source="$file"
      ;;
    reader)
      [ -n "$file" ] && [ -f "$file" ] && [ -r "$file" ] && source="$file"
      _gaia_rate_limits_scan "$directory"
      ;;
    *) return 1 ;;
  esac
  marker_arguments=(--arg marker "")
  if [ $# -ge 5 ]; then
    has_marker=true
    [ -f "$5" ] && [ -r "$5" ] && marker_arguments=(--rawfile marker "$5")
  fi
  output=$(_gaia_rate_limits_jq "$now" "$_GAIA_RATE_LIMITS_REPORT_PROGRAM" --arg mode "$mode" \
    --argjson has_marker "$has_marker" ${marker_arguments[@]+"${marker_arguments[@]}"} 2>/dev/null <"$source") || return 1
  first="${output%%$'\n'*}"
  case $first in
    "ok${tab}0") ;;
    "ok${tab}1")
      gaia_rate_limits_seven_day_set
      set_index=$_GAIA_RATE_LIMITS_SEVEN_DAY_SET_INDEX
      ;;
    *) return 1 ;;
  esac
  case $output in
    *$'\n'*) output="${output#*$'\n'}" ;;
    *) return 0 ;;
  esac
  while IFS= read -r record; do
    case $record in
      "$set_index$tab"*) printf '%s\n' "${record#"$set_index$tab"}" ;;
    esac
  done <<<"$output"
  return 0
}
