# shellcheck shell=bash
#
# Shared context threshold lib. The ONE tracked place the context checkpoint
# line, the statusline bands and the unit round count are defined; the
# statusline and the audit-loop bound hook / evaluator both source it, so the
# bar color and the checkpoint can never disagree.
#
# Owns: the checkpoint line (tokens capped by percent of the window), the
# yellow/red/fire/skull bands, K (rounds per unit), the freshness window for a
# context reading, and the per-session context file (path, write, read).
# Does not own: the round count, the grant size or the rubric defaults; those
# stay in audit-loop-eval.sh.
#
# Override rule. An optional machine-local file, <main>/.gaia/local/protected/checkpoint-override.json,
# may LOWER the line, for example {"version":1,"context_checkpoint":{"ask_tokens":100000}}
# (ask_tokens, ask_window_pct; version 1 is required). It can never raise it: an
# absent, invalid, out-of-range or raised value reads as the shipped default.
# The file is machine-local and writable by whoever runs the session, so a
# raise would let a session widen its own bound. A human edits it by hand;
# Claude's tool writes to it are denied by the audit loop write guard.
#
# Low confidence: the shipped defaults are tunable estimates, not measured
# facts. Their evidence lives in research notes, not here.
#
# Sourcing defines constants and functions only and runs no external command,
# so it is safe in the statusline's hot path, under `set -u`, and with PATH
# empty. Bash 3.2 compatible, integer arithmetic only, never `cd`s, and has no
# `set -e`. Double-sourcing is a no-op.

[ -n "${_GAIA_CONTEXT_LIBRARY_LOADED:-}" ] && return 0
_GAIA_CONTEXT_LIBRARY_LOADED=1

GAIA_CONTEXT_ASK_TOKENS_DEFAULT=300000
GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT=50
# shellcheck disable=SC2034 # read by the bound hook and the evaluator that source this lib
GAIA_CONTEXT_UNIT_ROUNDS=3
GAIA_CONTEXT_YELLOW_TOKENS=250000
GAIA_CONTEXT_YELLOW_WINDOW_PERCENT=30
GAIA_CONTEXT_FIRE_NUMERATOR=5
GAIA_CONTEXT_FIRE_DENOMINATOR=4
GAIA_CONTEXT_SKULL_NUMERATOR=3
GAIA_CONTEXT_SKULL_DENOMINATOR=2
GAIA_CONTEXT_FRESH_SECONDS=1800
GAIA_CONTEXT_FILE_VERSION=1
GAIA_CONTEXT_DEFAULT_WINDOW=1000000
GAIA_CONTEXT_YIELD_LIMIT=2
# shellcheck disable=SC2034 # read by the sub-agent hook that sources this lib
GAIA_CONTEXT_TRANSCRIPT_HEAD_BYTES=65536
GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES=65536
GAIA_CONTEXT_TRANSCRIPT_WIDE_BYTES=262144

# A reader treats a reading written this many seconds in the future as still
# plausible: the writer (statusline) and the reader (hook) are separate
# processes and their clocks may differ slightly.
_GAIA_CONTEXT_SKEW_SECONDS=60

# gaia_context_is_session_id <s>: rc 0 for a UUID-shaped id. Builtins only.
gaia_context_is_session_id() {
  local regex='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  [[ ${1:-} =~ $regex ]]
}

# gaia_context_file <main-root> <session_id>: print the context file path.
gaia_context_file() {
  gaia_context_is_session_id "${2:-}" || return 1
  printf '%s/.gaia/local/cache/shared/context/%s.json\n' "${1:-}" "$2"
}

# gaia_context_override <main-root>: print "<ask_tokens> <ask_window_pct>". Each
# field is honoured only as a JSON integer in 1..default; version must be 1.
gaia_context_override() {
  local file="${1:-}/.gaia/local/protected/checkpoint-override.json" override_values
  local default_tokens="$GAIA_CONTEXT_ASK_TOKENS_DEFAULT" default_percent="$GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT"
  if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
    override_values=$(jq -r --argjson default_tokens "$default_tokens" --argjson default_percent "$default_percent" '
      def lowered($maximum): type == "number" and . == floor and . >= 1 and . <= $maximum;
      if type == "object" and .version == 1 then
        (.context_checkpoint | if type == "object" then . else {} end) as $context_checkpoint
        | "\(if ($context_checkpoint.ask_tokens | lowered($default_tokens)) then $context_checkpoint.ask_tokens else $default_tokens end) \(if ($context_checkpoint.ask_window_pct | lowered($default_percent)) then $context_checkpoint.ask_window_pct else $default_percent end)"
      else empty end' "$file" 2>/dev/null) || override_values=""
    if [[ $override_values =~ ^[0-9]{1,12}\ [0-9]{1,12}$ ]]; then
      printf '%s\n' "$override_values"
      return 0
    fi
  fi
  printf '%s %s\n' "$default_tokens" "$default_percent"
}

# gaia_context_line <window_size> <ask_tokens> <ask_window_pct>
gaia_context_line() {
  local regex='^[0-9]{1,12}$' cap
  [[ ${1:-} =~ $regex && ${2:-} =~ $regex && ${3:-} =~ $regex ]] || return 2
  cap=$(($1 * $3 / 100))
  if [ "$2" -lt "$cap" ]; then printf '%s\n' "$2"; else printf '%s\n' "$cap"; fi
}

# gaia_context_bands <window_size> <line>: print "<yellow> <red> <fire> <skull>".
gaia_context_bands() {
  local regex='^[0-9]{1,12}$' yellow percent_anchor
  [[ ${1:-} =~ $regex && ${2:-} =~ $regex ]] || return 2
  yellow=$GAIA_CONTEXT_YELLOW_TOKENS
  percent_anchor=$(($1 * GAIA_CONTEXT_YELLOW_WINDOW_PERCENT / 100))
  [ "$percent_anchor" -lt "$yellow" ] && yellow=$percent_anchor
  [ "$2" -lt "$yellow" ] && yellow=$2
  printf '%s %s %s %s\n' "$yellow" "$2" \
    $(($2 * GAIA_CONTEXT_FIRE_NUMERATOR / GAIA_CONTEXT_FIRE_DENOMINATOR)) \
    $(($2 * GAIA_CONTEXT_SKULL_NUMERATOR / GAIA_CONTEXT_SKULL_DENOMINATOR))
}

# gaia_context_write <main-root> <session_id> <used_percentage> <used_tokens> <window_size> <epoch>
# Atomic: write <file>.tmp.$$ beside the target, then mv -f. The `.tmp.<pid>`
# pattern is what the state housekeeping sweep removes when orphaned.
gaia_context_write() {
  local root="${1:-}" session_id="${2:-}" used_percentage="${3:-}" tokens="${4:-}" window="${5:-}" epoch="${6:-}"
  local integer_pattern='^[0-9]{1,12}$' percentage_pattern='^[0-9]{1,3}(\.[0-9]{1,6})?$' file directory temporary_file
  [[ $tokens =~ $integer_pattern && $window =~ $integer_pattern && $epoch =~ $integer_pattern && $used_percentage =~ $percentage_pattern ]] || return 1
  file=$(gaia_context_file "$root" "$session_id") || return 1
  directory="${file%/*}"
  mkdir -p "$directory" 2>/dev/null || return 1
  temporary_file="$file.tmp.$$"
  printf '{"version":%s,"session_id":"%s","used_percentage":%s,"used_tokens":%s,"context_window_size":%s,"written_at":%s}\n' \
    "$GAIA_CONTEXT_FILE_VERSION" "$session_id" "$used_percentage" "$tokens" "$window" "$epoch" >"$temporary_file" 2>/dev/null || { rm -f "$temporary_file"; return 1; }
  mv -f "$temporary_file" "$file" 2>/dev/null || { rm -f "$temporary_file"; return 1; }
}

# gaia_context_read <main-root> <session_id> <now-epoch>: one line, either
# "fresh <used_tokens> <window_size>" (rc 0) or missing|stale|future|unparseable (rc 1).
gaia_context_read() {
  local file reading_fields used window written integer_pattern='^[0-9]{1,12}$'
  file=$(gaia_context_file "${1:-}" "${2:-}") || { printf 'missing\n'; return 1; }
  [[ ${3:-} =~ $integer_pattern ]] || { printf 'unparseable\n'; return 1; }
  [ -f "$file" ] || { printf 'missing\n'; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'unparseable\n'; return 1; }
  reading_fields=$(jq -r --argjson version "$GAIA_CONTEXT_FILE_VERSION" '
    def whole: type == "number" and . == floor and . >= 0;
    if type == "object" and .version == $version and (.used_tokens | whole) and (.context_window_size | whole) and (.written_at | whole)
    then "\(.used_tokens) \(.context_window_size) \(.written_at)" else empty end' "$file" 2>/dev/null) || reading_fields=""
  if ! [[ $reading_fields =~ ^[0-9]{1,12}\ [0-9]{1,12}\ [0-9]{1,12}$ ]]; then
    printf 'unparseable\n'
    return 1
  fi
  read -r used window written <<<"$reading_fields"
  if [ "$written" -gt $(($3 + _GAIA_CONTEXT_SKEW_SECONDS)) ]; then
    printf 'future\n'
    return 1
  fi
  if [ $(($3 - written)) -gt "$GAIA_CONTEXT_FRESH_SECONDS" ]; then
    printf 'stale\n'
    return 1
  fi
  printf 'fresh %s %s\n' "$used" "$window"
}

# gaia_context_effective_line <main-root> <window_size>: the checkpoint line with
# the lower-only override applied. rc 2 on a non-integer window.
gaia_context_effective_line() {
  local override_values ask_tokens ask_window_percent
  override_values=$(gaia_context_override "${1:-}") || return 2
  read -r ask_tokens ask_window_percent <<<"$override_values"
  gaia_context_line "${2:-}" "$ask_tokens" "$ask_window_percent"
}

# gaia_context_band <used_tokens> <window_size> <line>: green|yellow|red|fire|skull.
# A reading at or past a threshold is in that band, the same comparisons the
# statusline makes. rc 2 on a bad argument.
gaia_context_band() {
  local regex='^[0-9]{1,12}$' bands yellow red fire skull
  [[ ${1:-} =~ $regex ]] || return 2
  bands=$(gaia_context_bands "${2:-}" "${3:-}") || return 2
  read -r yellow red fire skull <<<"$bands"
  if [ "$((10#$1))" -ge "$skull" ]; then
    printf 'skull\n'
  elif [ "$((10#$1))" -ge "$fire" ]; then
    printf 'fire\n'
  elif [ "$((10#$1))" -ge "$red" ]; then
    printf 'red\n'
  elif [ "$((10#$1))" -ge "$yellow" ]; then
    printf 'yellow\n'
  else
    printf 'green\n'
  fi
}

# gaia_context_summary <used_tokens> <window_size>: "Context P% (Uk of Wk)", or
# "Context unavailable" for a zero window. rc 2 on a non-integer argument.
gaia_context_summary() {
  local regex='^[0-9]{1,12}$'
  [[ ${1:-} =~ $regex && ${2:-} =~ $regex ]] || return 2
  if [ "$((10#$2))" -le 0 ]; then
    printf 'Context unavailable\n'
    return 0
  fi
  printf 'Context %s%% (%sk of %sk)\n' "$((10#$1 * 100 / 10#$2))" "$((10#$1 / 1000))" "$((10#$2 / 1000))"
}

# gaia_context_yield_limit: print how many yields a unit of work is allowed.
gaia_context_yield_limit() {
  printf '%s\n' "$GAIA_CONTEXT_YIELD_LIMIT"
}

# gaia_context_last_window <main-root> <session_id>: print the session's
# context_window_size whatever the age of its reading (the window is fixed per
# session; freshness governs tokens, not window). rc 1 with no stdout when the
# file is missing, unparseable, a wrong version, or the window is not a
# positive whole number.
gaia_context_last_window() {
  local file window integer_pattern='^[0-9]{1,12}$'
  file=$(gaia_context_file "${1:-}" "${2:-}") || return 1
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  window=$(jq -r --argjson version "$GAIA_CONTEXT_FILE_VERSION" '
    if type == "object" and .version == $version
      and (.context_window_size | type == "number" and . == floor and . >= 1)
    then .context_window_size else empty end' "$file" 2>/dev/null) || return 1
  [[ $window =~ $integer_pattern ]] || return 1
  printf '%s\n' "$window"
}

# gaia_context_subagent_window <main-root> <session_id> <reading_tokens>: print
# the window a sub-agent's bands use. The main session's window stands while the
# reading fits inside it; a larger reading proves a larger window, so the
# default applies, as it does with no usable main reading. rc 2 on a
# non-integer reading.
gaia_context_subagent_window() {
  local integer_pattern='^[0-9]{1,12}$' last_window
  [[ ${3:-} =~ $integer_pattern ]] || return 2
  if last_window=$(gaia_context_last_window "${1:-}" "${2:-}") && [ "$((10#$3))" -le "$last_window" ]; then
    printf '%s\n' "$last_window"
  else
    printf '%s\n' "$GAIA_CONTEXT_DEFAULT_WINDOW"
  fi
}

# _gaia_context_tail_reading <transcript_path> <bytes>: scan the last <bytes>
# bytes for the last assistant usage record. A read that did not start at byte
# 0 may open mid-line, so its first line is dropped. Lines are split first and
# only those holding a usage object get a regex, because a regex over the whole
# buffer is slow in bash 3.2.
_gaia_context_tail_reading() {
  local path="$1" bytes="$2" size buffer line index body nested
  local -a candidates=()
  local type_pattern='(^|[^\\])"type":"assistant"'
  local usage_pattern='(^|[^\\])"usage":\{([^{}]*(\{[^{}]*\}[^{}]*)*)\}'
  local nested_pattern='\{[^{}]*\}'
  local input_pattern='(^|[^\\])"input_tokens":([0-9]{1,12})([^0-9]|$)'
  local creation_pattern='(^|[^\\])"cache_creation_input_tokens":([0-9]{1,12})([^0-9]|$)'
  local read_pattern='(^|[^\\])"cache_read_input_tokens":([0-9]{1,12})([^0-9]|$)'
  local input_tokens creation_tokens read_tokens skip_first=0
  size=$(wc -c <"$path" 2>/dev/null) || return 1
  size=${size//[[:space:]]/}
  [ "$size" -gt "$bytes" ] && skip_first=1
  buffer=$(tail -c "$bytes" "$path" 2>/dev/null) || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$skip_first" -eq 1 ]; then
      skip_first=0
      continue
    fi
    case $line in
      *'"usage":{'*) candidates+=("$line") ;;
    esac
  done <<<"$buffer"
  index=${#candidates[@]}
  while [ "$index" -gt 0 ]; do
    index=$((index - 1))
    line=${candidates[$index]}
    [[ $line =~ $type_pattern ]] || continue
    [[ $line =~ $usage_pattern ]] || continue
    body=${BASH_REMATCH[2]}
    while [[ $body =~ $nested_pattern ]]; do
      nested=${BASH_REMATCH[0]}
      body=${body/"$nested"/}
    done
    [[ $body =~ $input_pattern ]] || continue
    input_tokens=${BASH_REMATCH[2]}
    [[ $body =~ $creation_pattern ]] || continue
    creation_tokens=${BASH_REMATCH[2]}
    [[ $body =~ $read_pattern ]] || continue
    read_tokens=${BASH_REMATCH[2]}
    printf '%s\n' "$((10#$input_tokens + 10#$creation_tokens + 10#$read_tokens))"
    return 0
  done
  return 1
}

# gaia_context_transcript_reading <transcript_path>: print input + cache
# creation + cache read tokens of the last assistant usage record, read from
# the tail of the file and widened once when the tail holds none. A quote
# preceded by a backslash sits inside a JSON string (a tool result that printed
# a transcript) and never counts. rc 1 with no stdout when nothing is found.
gaia_context_transcript_reading() {
  local path="${1:-}" size
  [ -f "$path" ] && [ -r "$path" ] || return 1
  _gaia_context_tail_reading "$path" "$GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES" && return 0
  size=$(wc -c <"$path" 2>/dev/null) || return 1
  size=${size//[[:space:]]/}
  [ "$size" -gt "$GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES" ] || return 1
  _gaia_context_tail_reading "$path" "$GAIA_CONTEXT_TRANSCRIPT_WIDE_BYTES"
}
