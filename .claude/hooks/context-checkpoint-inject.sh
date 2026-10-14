#!/usr/bin/env bash
# PostToolUse hook, registered with no matcher so it runs after every tool call
# of a session: the context checkpoint. Claude cannot see its own context
# reading; only the statusline receives it and writes it to the per-session
# context file (context-checkpoint-lib.sh, gaia_context_write). The first time a
# main session's fresh reading is at or past the red band, this hook injects,
# through hookSpecificOutput.additionalContext, three header lines (the band and
# the reading summary, the session id, the resolved save path) followed by
# .claude/doctrine/context-checkpoint.md verbatim; it does so once more at each
# of the fire and skull bands. Every band value comes from
# context-checkpoint-lib.sh; none is spelled here.
#
# Silent for: a sub-agent payload (an `agent_id` key), any event other than
# PostToolUse, a reading that is not fresh, a band already marked, a missing or
# oversize doctrine file, and a session the audit loop records. The audit loop
# owns its own checkpoint: a session is in it when the non-closed state file for
# the payload cwd's branch key has a history.units[] or history.checkpoints[]
# entry carrying this session id. Only that one file is read; a state file on
# another branch never silences.
#
# Exit ladder, cheapest first, because every tool call pays it: raw pattern
# checks on the payload (event, agent_id, session id, cwd) with bash only; the
# main root from the on-disk git layout with no git process; the marker read;
# then, only past that, one jq for the context reading; the band; the doctrine
# file; the branch key and default branch from git's files; and one more jq that
# both confirms the raw checks against a real parse and runs the audit-loop
# predicate. The sub-agent and every-band-marked paths start no git and no jq.
# git runs only on a layout the file reader does not recognize (reftable, a
# submodule or other non-standard git dir, an unrecognized HEAD).
#
# Marker: <main root>/.gaia/local/cache/context-checkpoint/<session id>, one line
# holding the highest band fired. Firing a band marks it and every lower band,
# so a jump past several bands fires once, for the highest. The main root comes
# from the payload cwd, so the main checkout and its linked worktrees share one
# reading and one marker. The marker is written after the output, through a
# temporary file and mv, so a failed write costs a repeat, never a lost
# instruction. Compaction keeps the session id, so marked bands stay marked.
#
# Fail open: every path exits 0, writes nothing to stderr, and any read or parse
# failure emits nothing and records no marker.

set -uo pipefail
trap 'exit 0' ERR
exec 2>/dev/null

# Byte-wise string handling and pattern ranges. Not exported.
LC_ALL=C

here="${BASH_SOURCE[0]}"
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac
# Absolute, because the main-root walk below moves this process's directory.
case "$here" in /*) ;; *) here="$PWD/$here" ;; esac
scripts="$here/../../.gaia/scripts"
doctrine_document="$here/../doctrine/context-checkpoint.md"
maximum_doctrine_bytes=3584

# `cat`, not `read -d ''`: bash 3.2 reads a pipe one byte per read() call,
# which costs tens of milliseconds on a large tool_response.
payload=$(cat)

# Raw checks, bash only. An escaped key sits inside a string value, so a key
# counts only when no backslash precedes its opening quote. A false agent_id
# hit only skips one call; the jq confirm below is the authority before any
# output or marker write.
event_pattern='(^|[^\\])"hook_event_name"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $event_pattern ]] || exit 0
[ "${BASH_REMATCH[2]}" = PostToolUse ] || exit 0
agent_pattern='(^|[^\\])"agent_id"[[:space:]]*:'
[[ $payload =~ $agent_pattern ]] && exit 0

session_pattern='(^|[^\\])"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $session_pattern ]] || exit 0
session_id="${BASH_REMATCH[2]}"
cwd_pattern='(^|[^\\])"cwd"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $cwd_pattern ]] || exit 0
cwd="${BASH_REMATCH[2]}"
case "$cwd" in /*) ;; *) exit 0 ;; esac
case "$cwd" in *\\*) exit 0 ;; esac
[ -d "$cwd" ] || exit 0

# shellcheck source=/dev/null
. "$scripts/context-checkpoint-lib.sh" || exit 0
gaia_context_is_session_id "$session_id" || exit 0

# Main root from the on-disk layout: the first .git walking up from cwd. A .git
# directory is the main checkout itself; a .git file whose commondir resolves to
# a directory named .git is a linked worktree of that checkout. Anything else
# goes through the shared resolver, and the branch read below goes through git.
# resolve_physical <directory>: sets $physical_directory. It changes this
# process's own directory rather than forking a subshell for `cd -P`, because
# every path past the sub-agent exit pays it; nothing after it reads the cwd.
resolve_physical() {
  physical_directory=""
  CDPATH="" cd -P "$1" && physical_directory=$PWD
}

main_root="" git_directory="" common_directory="" use_git=0
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
  use_git=1
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

# Marker: the highest band already fired. skull is every band, the only exit
# allowed before the context read.
marker_directory="$main_root/.gaia/local/cache/context-checkpoint"
marker="$marker_directory/$session_id"
marked_band=""
if [ -f "$marker" ]; then IFS= read -r marked_band <"$marker" || true; fi
band_rank "$marked_band"
marked_rank=$rank
[ "$marked_rank" -lt 4 ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
now="${EPOCHSECONDS:-}"
[ -n "$now" ] || now=$(date +%s) || exit 0
# The reading's band and summary come out of one subshell as two lines: every
# `$()` is a fork, and every call past the marker pays this block. No `case`
# inside it: bash 3.2 misparses a case arm's `)` within `$( )`, and only when
# the line runs, so `bash -n` does not catch it.
positive_integer_pattern='^[1-9][0-9]*$'
checkpoint_fields=$(
  reading=$(gaia_context_read "$main_root" "$session_id" "$now") || exit 1
  [ "${reading%% *}" = fresh ] || exit 1
  reading="${reading#fresh }"
  used="${reading%% *}" window="${reading#* }"
  # A zero window makes every band threshold zero, which would read as skull.
  [[ $window =~ $positive_integer_pattern ]] || exit 1
  line=$(gaia_context_effective_line "$main_root" "$window") || exit 1
  gaia_context_band "$used" "$window" "$line" || exit 1
  gaia_context_summary "$used" "$window" || exit 1
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

# shellcheck source=/dev/null
. "$scripts/audit-loop-state-lib.sh" || exit 0

# Branch key and default branch, matching what gaia_loop_key and
# gaia_usage_default_branch print, read from git's files: HEAD from the git dir,
# origin/HEAD and the main/master refs (loose or packed) from the common dir.
key="" default_branch="" raw_branch=""
if [ "$use_git" = 0 ]; then
  head_line=""
  IFS= read -r head_line <"$git_directory/HEAD" || true
  case "$head_line" in
    "ref: refs/heads/"?*) raw_branch="${head_line#ref: refs/heads/}" ;;
    "ref: "* | *[!0-9a-f]* | "") use_git=1 ;;
    *) raw_branch="" ;;
  esac
fi

# has_reference <ref>: a loose ref file, or a packed-refs line naming the ref.
packed_references=""
packed_references_read=0
has_reference() {
  [ -f "$common_directory/$1" ] && return 0
  if [ "$packed_references_read" = 0 ]; then
    packed_references_read=1
    if [ -f "$common_directory/packed-refs" ]; then
      IFS= read -r -d '' packed_references <"$common_directory/packed-refs" || true
    fi
  fi
  case "$packed_references" in *" $1"$'\n'* | *" $1") return 0 ;; esac
  return 1
}

if [ "$use_git" = 1 ]; then
  key=$(gaia_loop_key "$cwd" 2>/dev/null) || key=""
  if [ -n "$key" ]; then
    # shellcheck source=/dev/null
    . "$scripts/usage-lib.sh" || exit 0
    default_branch=$(gaia_usage_default_branch "$cwd" 2>/dev/null) || default_branch=""
  fi
elif [ -n "$raw_branch" ]; then
  case "$raw_branch" in
    worktree-* | *+*) normalized_branch=$(gaia_branch_normalize "$raw_branch") || normalized_branch="" ;;
    *) normalized_branch="$raw_branch" ;;
  esac
  if _gaia_loop_keyable "$normalized_branch"; then
    key="$normalized_branch"
    remote_head=""
    if [ -f "$common_directory/refs/remotes/origin/HEAD" ]; then
      IFS= read -r remote_head <"$common_directory/refs/remotes/origin/HEAD" || true
    fi
    case "$remote_head" in "ref: "?*) remote_head="${remote_head#ref: }" ;; *) remote_head="" ;; esac
    remote_head="${remote_head#refs/remotes/origin/}"
    if [ -n "$remote_head" ]; then
      default_branch="$remote_head"
    elif has_reference refs/heads/main || has_reference refs/remotes/origin/main; then
      default_branch=main
    elif has_reference refs/heads/master || has_reference refs/remotes/origin/master; then
      default_branch=master
    else
      default_branch=main
    fi
  fi
fi

# One jq: confirm the raw checks against a real parse of the payload, and run
# the audit-loop predicate over the cwd branch's non-closed state file. Any
# mismatch, parse failure, or in-loop answer emits nothing.
state_arguments=(--argjson state '[]')
run_directory=""
if [ -n "$key" ]; then
  key_paths=$(gaia_loop_state_file "$main_root" "$key" && gaia_loop_run_directory "$main_root" "$key") || exit 0
  state_file="${key_paths%%$'\n'*}"
  run_directory="${key_paths#*$'\n'}"
  [ ! -f "$state_file" ] || state_arguments=(--slurpfile state "$state_file")
fi
# shellcheck disable=SC2016 # jq variables, not shell expansions
verdict=$(jq -r --arg session_id "$session_id" --arg working_directory "$cwd" ${state_arguments[@]+"${state_arguments[@]}"} '
  def recorded:
    [$state[] | (.history.units[]?, .history.checkpoints[]?)
      | select(type == "object" and .session_id == $session_id)] | length > 0;
  if type == "object" and .hook_event_name == "PostToolUse" and (has("agent_id") | not)
     and .session_id == $session_id and .cwd == $working_directory
  then (if recorded then "in-loop" else "emit" end)
  else "mismatch" end' <<<"$payload") || exit 0
[ "$verdict" = emit ] || exit 0

if [ -n "$key" ] && [ -n "$run_directory" ] && [ "$key" != "$default_branch" ]; then
  save_path="$run_directory/STATE.md"
else
  save_path="$main_root/.gaia/local/runs/session-$session_id/STATE.md"
fi

text="Context checkpoint: $band band reached ($summary)."$'\n'"Session id: $session_id"$'\n'"Save path: $save_path"$'\n'"$doctrine"

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
# Three header lines plus at least one doctrine line, or the read failed.
[ "$line_count" -gt 3 ] || exit 0
printf -v text '%s\\n' ${encoded_lines[@]+"${encoded_lines[@]}"}
text="${text%\\n}"

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$text"

if [ -d "$marker_directory" ] || mkdir -p "$marker_directory"; then
  temporary_marker="$marker_directory/.$session_id.$$"
  if printf '%s\n' "$band" >"$temporary_marker"; then
    mv -f "$temporary_marker" "$marker" || rm -f "$temporary_marker"
  else
    rm -f "$temporary_marker"
  fi
fi
exit 0
