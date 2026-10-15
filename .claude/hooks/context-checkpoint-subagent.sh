#!/usr/bin/env bash
# PostToolUse hook, registered with no matcher so it runs after every tool call
# of a session: the sub-agent context checkpoint. A sub-agent renders no
# statusline, so no context file exists for it; this hook reads the sub-agent's
# own reading from the last usage record in its transcript instead. The first
# time an opted-in sub-agent's reading is at or past the red band, it injects,
# through hookSpecificOutput.additionalContext, two header lines (the band and
# the reading summary, the handoff path) followed by
# .claude/doctrine/context-yield.md verbatim; it does so once more at each of
# the fire and skull bands. Every band, window and read bound comes from
# context-checkpoint-lib.sh; none is spelled here.
#
# Opt-in: the dispatcher ends the dispatch prompt with the line
# `Yield handoff: <absolute path>`. Only the first transcript record (the
# dispatch prompt, one JSON string on line 1) is read, and only an occurrence
# that ends that prompt string counts, so a task doc or example quoted earlier
# in the prompt never opts an agent in. The path must sit under the main
# root's .gaia/local/ or its notebook root and name a handoff file in the dispatcher's shape; any
# other path, or one holding an escape, reads as not opted in.
#
# Silent for: a main-session payload (no `agent_id` key), any event other than
# PostToolUse, a payload whose shape checks fail, an agent that did not opt in,
# a band already marked, a missing transcript or one with no usage record
# within the widened read, and a missing or oversize doctrine file. A main
# payload whose tool input carries an `agent_id` lookalike is silent too: the
# raw key match can find that lookalike, so a real parse confirms the
# top-level fields before any marker write and before every opted-in read.
#
# Exit ladder, cheapest first, because every tool call pays it: raw pattern
# checks on the payload with bash only (the main-session path ends at the first
# of them); shape checks on the agent id, session id, transcript path and cwd;
# the main root from the on-disk git layout with no git process; the marker
# read, which ends a not-opted-in or every-band-marked agent; on first sight
# only, the bounded head read for the opt-in; then one jq to confirm the raw
# fields; the transcript tail read; the window, line and band; the doctrine.
#
# Marker: <main root>/.gaia/local/cache/context-checkpoint-agents/<session id>.<agent id>,
# two lines, `opt-in: none` or `opt-in: <handoff path>`, then `band: none` or
# the highest band fired. The opt-in is cached on first sight so the head is
# read once per agent. Firing a band marks it and every lower band, so a jump
# past several bands fires once, for the highest. Every write goes through a
# temporary file and mv, and the band is written after the output, so a failed
# write costs a repeat, never a lost instruction or a torn marker.
#
# Fail open: every path exits 0, writes nothing to stderr, and any read or parse
# failure emits nothing and records no band.

set -uo pipefail
trap 'exit 0' ERR
exec 2>/dev/null

# Byte-wise string handling and pattern ranges, and `read -n` counting bytes.
# Not exported.
LC_ALL=C

here="${BASH_SOURCE[0]}"
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac
# Absolute, because the main-root walk below moves this process's directory.
case "$here" in /*) ;; *) here="$PWD/$here" ;; esac
scripts="$here/../../.gaia/scripts"
doctrine_document="$here/../doctrine/context-yield.md"
maximum_doctrine_bytes=3584

# `cat`, not `read -d ''`: bash 3.2 reads a pipe one byte per read() call,
# which costs tens of milliseconds on a large tool_response.
payload=$(cat)

# Raw checks, bash only. An escaped key sits inside a string value, so a key
# counts only when no backslash precedes its opening quote. A key inside
# tool_input is unescaped too, so these values are candidates only; the jq
# confirm below is the authority before any write or output.
event_pattern='(^|[^\\])"hook_event_name"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $event_pattern ]] || exit 0
[ "${BASH_REMATCH[2]}" = PostToolUse ] || exit 0
agent_pattern='(^|[^\\])"agent_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $agent_pattern ]] || exit 0
agent_id="${BASH_REMATCH[2]}"
session_pattern='(^|[^\\])"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $session_pattern ]] || exit 0
session_id="${BASH_REMATCH[2]}"
transcript_pattern='(^|[^\\])"transcript_path"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $transcript_pattern ]] || exit 0
transcript_path="${BASH_REMATCH[2]}"
cwd_pattern='(^|[^\\])"cwd"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $cwd_pattern ]] || exit 0
cwd="${BASH_REMATCH[2]}"

# Shape checks before any of these values builds a path: the agent id and
# session id are file-name components, the transcript path is a directory base.
agent_id_pattern='^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$'
[[ $agent_id =~ $agent_id_pattern ]] || exit 0
case "$transcript_path" in /*.jsonl) ;; *) exit 0 ;; esac
case "$transcript_path" in *\\* | */../*) exit 0 ;; esac
transcript_base="${transcript_path%.jsonl}"
case "$transcript_base" in */. | */..) exit 0 ;; esac
case "$cwd" in /*) ;; *) exit 0 ;; esac
case "$cwd" in *\\*) exit 0 ;; esac
[ -d "$cwd" ] || exit 0

# shellcheck source=/dev/null
. "$scripts/context-checkpoint-lib.sh" || exit 0
gaia_context_is_session_id "$session_id" || exit 0

# Main root from the on-disk layout: the first .git walking up from cwd. A .git
# directory is the main checkout itself; a .git file whose commondir resolves to
# a directory named .git is a linked worktree of that checkout. Anything else
# goes through the shared resolver. The same walk as the main-session hook.
# resolve_physical <directory>: sets $physical_directory. It changes this
# process's own directory rather than forking a subshell for `cd -P`, because
# every sub-agent call pays it; nothing after it reads the cwd.
resolve_physical() {
  physical_directory=""
  CDPATH="" cd -P "$1" && physical_directory=$PWD
}

main_root="" git_directory="" common_directory=""
search_directory="${cwd%/}"
while :; do
  if [ -d "$search_directory/.git" ]; then
    git_directory="$search_directory/.git"
    common_directory="$git_directory"
    if [ -f "$git_directory/HEAD" ] && [ ! -e "$git_directory/commondir" ]; then
      resolve_physical "${search_directory:-/}" && main_root=$physical_directory
    fi
    break
  fi
  if [ -f "$search_directory/.git" ]; then
    git_file_line=""
    IFS= read -r git_file_line <"$search_directory/.git" || true
    case "$git_file_line" in
      "gitdir: "?*)
        git_directory="${git_file_line#gitdir: }"
        case "$git_directory" in /*) ;; *) git_directory="$search_directory/$git_directory" ;; esac
        if [ -f "$git_directory/HEAD" ] && [ -f "$git_directory/commondir" ]; then
          commondir_line=""
          IFS= read -r commondir_line <"$git_directory/commondir" || true
          case "$commondir_line" in
            "") ;;
            /*) common_directory="$commondir_line" ;;
            *) common_directory="$git_directory/$commondir_line" ;;
          esac
          if [ -n "$common_directory" ]; then
            resolve_physical "$common_directory" || true
            common_directory=$physical_directory
            case "$common_directory" in /?*/.git) main_root="${common_directory%/.git}" ;; esac
          fi
        fi
        ;;
    esac
    break
  fi
  [ -n "$search_directory" ] || break
  search_directory="${search_directory%/*}"
done
if [ -n "$main_root" ] && [ -d "$common_directory/reftable" ]; then main_root=""; fi
if [ -z "$main_root" ]; then
  # shellcheck source=/dev/null
  . "$scripts/main-root-lib.sh" || exit 0
  main_root=$(gaia_resolve_main_root "$cwd" 2>/dev/null) || exit 0
  [ -n "$main_root" ] || exit 0
fi

# band_rank <band>: sets $rank; anything unrecognized ranks as green.
band_rank() {
  case "$1" in
    yellow) rank=1 ;;
    red) rank=2 ;;
    fire) rank=3 ;;
    skull) rank=4 ;;
    *) rank=0 ;;
  esac
}

# valid_handoff_path <path>: rc 0 for a handoff path in the dispatcher's shape
# under this main root. The path is echoed into the agent's context and names a
# file the agent will write, so anything else reads as not opted in.
handoff_tail_pattern='/handoffs/(phase-[0-9]+-task-[a-z0-9][a-z0-9-]*|planner)-yield-[0-9]+\.md$'
valid_handoff_path() {
  case "$1" in "$main_root/.gaia/local/"?* | "$main_root/.notebook/"?*) ;; *) return 1 ;; esac
  case "$1" in *\\* | *\"* | *//* | */./* | */../* | *[$'\001'-$'\037'$'\177']*) return 1 ;; esac
  [[ $1 =~ $handoff_tail_pattern ]]
}

# confirm_payload: rc 0 only when a real parse of the payload agrees with every
# raw extraction above, at the top level.
confirm_payload() {
  command -v jq >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016 # jq variables, not shell expansions
  jq -e --arg agent_id "$agent_id" --arg session_id "$session_id" \
    --arg transcript_path "$transcript_path" --arg working_directory "$cwd" '
    type == "object" and .hook_event_name == "PostToolUse" and .agent_id == $agent_id
    and .session_id == $session_id and .transcript_path == $transcript_path
    and .cwd == $working_directory' >/dev/null <<<"$payload"
}

marker_directory="$main_root/.gaia/local/cache/context-checkpoint-agents"
marker="$marker_directory/$session_id.$agent_id"

# write_marker <opt-in> <band>: the two-line marker, through a temporary file
# and mv so a reader never sees a torn one.
write_marker() {
  [ -d "$marker_directory" ] || mkdir -p "$marker_directory" || return 1
  temporary_marker="$marker_directory/.$session_id.$agent_id.$$"
  if printf 'opt-in: %s\nband: %s\n' "$1" "$2" >"$temporary_marker"; then
    mv -f "$temporary_marker" "$marker" && return 0
  fi
  rm -f "$temporary_marker"
  return 1
}

subagent_transcript="$transcript_base/subagents/agent-$agent_id.jsonl"

# Marker read. An unreadable or malformed marker is silent rather than
# re-derived: the hook never emits from a state it cannot read.
marked_opt_in="" marked_band=""
if [ -f "$marker" ]; then
  opt_in_line="" band_line=""
  { IFS= read -r opt_in_line || true; IFS= read -r band_line || true; } <"$marker" || exit 0
  case "$opt_in_line" in "opt-in: "?*) marked_opt_in="${opt_in_line#opt-in: }" ;; *) exit 0 ;; esac
  case "$band_line" in "band: "?*) marked_band="${band_line#band: }" ;; *) exit 0 ;; esac
fi
# skull is every band, the cheapest exit for an agent that has seen them all.
[ "$marked_band" != skull ] || exit 0
# A cached not-opted-in marker governs, whatever the transcript head says now.
[ "$marked_opt_in" != none ] || exit 0

confirmed=0
if [ -n "$marked_opt_in" ]; then
  handoff_path="$marked_opt_in"
  valid_handoff_path "$handoff_path" || exit 0
else
  # First sight. A missing transcript is also what an agent_id lookalike in a
  # main payload resolves to, so nothing is written for it.
  [ -f "$subagent_transcript" ] && [ -r "$subagent_transcript" ] || exit 0
  # One byte past the bound, so a first record of exactly the bound with no
  # newline (still being written) is told apart from one longer than it.
  head_bytes="$GAIA_CONTEXT_TRANSCRIPT_HEAD_BYTES"
  first_record="" head_status=0
  IFS= read -r -n $((head_bytes + 1)) first_record <"$subagent_transcript" || head_status=1
  # A read that hit end of file before a newline or the byte limit found a
  # first record still being written: no marker, so the next call retries.
  [ "$head_status" -eq 0 ] || exit 0
  opt_in=none
  # A record of the bound or longer leaves no newline inside the bound.
  if [ "${#first_record}" -lt "$head_bytes" ]; then
    # The line must end the prompt string: an escaped newline or the string's
    # opening quote before it, an optional escaped newline and the closing
    # quote after it. A path holding a backslash (an escape) never matches.
    opt_in_pattern='(^|[^\\])(\\n|")Yield handoff: ([^"\\]*)(\\n)?"'
    if [[ $first_record =~ $opt_in_pattern ]]; then
      candidate_path="${BASH_REMATCH[3]}"
      if valid_handoff_path "$candidate_path"; then opt_in="$candidate_path"; fi
    fi
  fi
  confirm_payload || exit 0
  confirmed=1
  write_marker "$opt_in" none || true
  [ "$opt_in" != none ] || exit 0
  handoff_path="$opt_in"
  marked_band=none
fi
band_rank "$marked_band"
marked_rank=$rank

# Every opted-in call, before any read or output: the raw agent_id can be a
# lookalike inside tool_input naming a real opted-in agent of this session.
[ "$confirmed" = 1 ] || confirm_payload || exit 0

# The reading's band and summary come out of one subshell as two lines: every
# `$()` is a fork. No `case` inside it: bash 3.2 misparses a case arm's `)`
# within `$( )`, and only when the line runs, so `bash -n` does not catch it.
positive_integer_pattern='^[1-9][0-9]*$'
checkpoint_fields=$(
  tokens=$(gaia_context_transcript_reading "$subagent_transcript") || exit 1
  window=$(gaia_context_subagent_window "$main_root" "$session_id" "$tokens") || exit 1
  # A zero window makes every band threshold zero, which would read as skull.
  [[ $window =~ $positive_integer_pattern ]] || exit 1
  line=$(gaia_context_effective_line "$main_root" "$window") || exit 1
  gaia_context_band "$tokens" "$window" "$line" || exit 1
  gaia_context_summary "$tokens" "$window" || exit 1
) || exit 0
band="${checkpoint_fields%%$'\n'*}"
summary="${checkpoint_fields#*$'\n'}"
band_rank "$band"
[ "$rank" -ge 2 ] || exit 0
[ "$rank" -gt "$marked_rank" ] || exit 0

# Doctrine: present, readable, within the byte cap. At most one byte past the
# cap is read, so an oversize file costs the same as a full one and is skipped,
# never truncated.
[ -f "$doctrine_document" ] && [ -r "$doctrine_document" ] || exit 0
doctrine=""
IFS= read -r -d '' -n $((maximum_doctrine_bytes + 1)) doctrine <"$doctrine_document" || true
[ -n "$doctrine" ] || exit 0
[ "${#doctrine}" -le "$maximum_doctrine_bytes" ] || exit 0

text="Sub-agent context checkpoint: $band band reached ($summary)."$'\n'"Handoff path: $handoff_path"$'\n'"$doctrine"

# JSON string encoding in bash, one line at a time: a global ${text//…}
# substitution or a `*x*` match over the whole text costs milliseconds on bash
# 3.2, while the same work on short lines is cheap. Backslash first, so no later
# escape is doubled. The here-string adds one trailing newline, so the joined
# text ends in one `\n` too many, removed after the join.
encoded_lines=()
line_count=0
while IFS= read -r text_line; do
  case "$text_line" in
    *[\\\"$'\001'-$'\037']*)
      text_line=${text_line//\\/\\\\}
      text_line=${text_line//\"/\\\"}
      text_line=${text_line//$'\t'/\\t}
      text_line=${text_line//$'\r'/\\r}
      text_line=${text_line//$'\b'/\\b}
      text_line=${text_line//$'\f'/\\f}
      case "$text_line" in
        *[$'\001'-$'\037']*)
          code=1
          while [ "$code" -lt 32 ]; do
            printf -v octal '%03o' "$code"
            printf -v control_character '%b' "\\0$octal"
            case "$text_line" in
              *"$control_character"*)
                printf -v escaped_character '\\u%04x' "$code"
                text_line=${text_line//"$control_character"/$escaped_character}
                ;;
            esac
            code=$((code + 1))
          done
          ;;
      esac
      ;;
  esac
  encoded_lines[line_count]=$text_line
  line_count=$((line_count + 1))
done <<<"$text"
# Two header lines plus at least one doctrine line, or the read failed.
[ "$line_count" -gt 2 ] || exit 0
printf -v text '%s\\n' ${encoded_lines[@]+"${encoded_lines[@]}"}
text="${text%\\n}"

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$text"

write_marker "$handoff_path" "$band" || true
exit 0
