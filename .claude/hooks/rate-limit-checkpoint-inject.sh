#!/usr/bin/env bash
# PreToolUse hook, registered in .claude/settings.json with the matcher
# `Agent|Task|Workflow` as its own entry: the rate-limit checkpoint. A session
# about to fan out large work cannot see that a rate-limit window is nearly
# spent. The statusline writes the account's windows to the shared reading
# (.gaia/scripts/rate-limits-lib.sh); the first time a main session dispatches
# while an unexpired window is at or above the warning band and this session has
# not been told about that band of that window, this hook injects, through
# hookSpecificOutput.additionalContext, one header line per such window, every
# reader line of the shared reading, and a pointer to
# .claude/doctrine/rate-limit-checkpoint.md. It speaks again for a higher band
# of the same window, and for a new window (a reset time past the library's
# same-window slack). Every band, the slack and the reader's lines come from
# .gaia/scripts/rate-limits-lib.sh; none is spelled here.
#
# The triggering dispatch proceeds unchanged: this hook never blocks and never
# prints a permission decision. The injected reading governs the session's next
# dispatches, as the doctrine says.
#
# Silent for: a sub-agent payload (an `agent_id` key, which covers an agent a
# Workflow spawns), any event other than PreToolUse, any tool other than
# Agent, Task or Workflow, a session id that is not UUID-shaped, no shared
# reading, an expired window, a window below the warning band, a window with a
# malformed figure, an unparseable or wrong-version file, a band already marked,
# and an injection whose encoded text would pass the byte cap.
#
# Exit ladder, cheapest first: raw pattern checks on the payload with bash only
# (event, agent_id, tool name, session id, cwd); the fast pre-check, which
# sources only main-root-lib.sh and rate-limit-main-root-probe-lib.sh, trusts
# gaia_resolve_main_root_fast for "absent" only, and exits when its root holds
# no shared file, before any git process (any other outcome changes nothing);
# context-checkpoint-lib.sh and the session id check;
# rate-limits-lib.sh; gaia_resolve_main_root and the authoritative shared-file
# check; then the one jq of the run, inside gaia_rate_limits_report, which also
# emits the merged marker body. The hook never runs `rate-limits.sh read` and
# never parses the marker itself.
#
# Marker: <main root>/.gaia/local/cache/rate-limit-checkpoint/<session id>.json,
# a JSON object holding, per window name, the reset time and the highest band
# told. The library computes the whole body; the hook writes it verbatim,
# after the output, through a temporary file and mv, so a failed write costs a
# repeat, never a lost instruction. The main root comes from the payload cwd, so
# the main checkout and its linked worktrees share one reading and one marker.
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
case "$here" in /*) ;; *) here="$PWD/$here" ;; esac
scripts="$here/../../.gaia/scripts"
maximum_text_bytes=2048
policy_line='Policy: .claude/doctrine/rate-limit-checkpoint.md'

payload=$(cat)

# Raw checks, bash only. An escaped key sits inside a string value, so a key
# counts only when no backslash precedes its opening quote. A false agent_id
# hit only skips one dispatch's advice.
event_pattern='(^|[^\\])"hook_event_name"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $event_pattern ]] || exit 0
[ "${BASH_REMATCH[2]}" = PreToolUse ] || exit 0
agent_pattern='(^|[^\\])"agent_id"[[:space:]]*:'
[[ $payload =~ $agent_pattern ]] && exit 0
tool_pattern='(^|[^\\])"tool_name"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $tool_pattern ]] || exit 0
case "${BASH_REMATCH[2]}" in Agent | Task | Workflow) ;; *) exit 0 ;; esac
session_pattern='(^|[^\\])"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $session_pattern ]] || exit 0
session_id="${BASH_REMATCH[2]}"
cwd_pattern='(^|[^\\])"cwd"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $payload =~ $cwd_pattern ]] || exit 0
cwd="${BASH_REMATCH[2]}"
case "$cwd" in /*) ;; *) exit 0 ;; esac
case "$cwd" in *\\*) exit 0 ;; esac
[ -d "$cwd" ] || exit 0

# Fast pre-check (exit ladder above). The relative path is read from
# rate-limits-lib.sh's own assignment, not sourced, so this exit skips that
# library's load and the path is never spelled here.
# A failed load of rate-limit-main-root-probe-lib.sh skips only the pre-check;
# a failed load of main-root-lib.sh also leaves gaia_resolve_main_root
# undefined, so the hook exits silently at the full resolution below.
fast_precheck_ready=0
# shellcheck source=/dev/null
if . "$scripts/main-root-lib.sh" && . "$scripts/rate-limit-main-root-probe-lib.sh"; then
  fast_precheck_ready=1
fi
shared_relative=""
while IFS= read -r library_line; do
  case "$library_line" in
    _GAIA_RATE_LIMITS_RELATIVE_PATH=*)
      shared_relative="${library_line#*=}"
      break
      ;;
  esac
done <"$scripts/rate-limits-lib.sh"
case "$shared_relative" in
  '' | *[!A-Za-z0-9_./-]*) shared_relative="" ;;
esac
if [ "$fast_precheck_ready" = 1 ] && [ -n "$shared_relative" ] && precheck_root=$(gaia_resolve_main_root_fast "$cwd") && [ ! -f "$precheck_root/$shared_relative" ]; then
  exit 0
fi

# shellcheck source=/dev/null
. "$scripts/context-checkpoint-lib.sh" || exit 0
gaia_context_is_session_id "$session_id" || exit 0
# shellcheck source=/dev/null
. "$scripts/rate-limits-lib.sh" || exit 0

main_root=$(gaia_resolve_main_root "$cwd") || exit 0
[ -n "$main_root" ] || exit 0

# Authoritative check: no shared reading, nothing to say.
shared_file=$(gaia_rate_limits_file "$main_root")
[ -f "$shared_file" ] || exit 0

marker_directory="$main_root/.gaia/local/cache/rate-limit-checkpoint"
marker="$marker_directory/$session_id.json"
now=$(gaia_rate_limits_now) || exit 0
report=$(gaia_rate_limits_report "$main_root" "$now" "$marker") || exit 0

headers=() readings=() marker_body=""
tab=$'\t'
while IFS= read -r record; do
  case "$record" in
    "due$tab"*)
      IFS="$tab" read -r _ due_name due_band due_percentage due_label _ <<<"$record"
      gaia_rate_limits_is_window_name "$due_name" || exit 0
      case "$due_band" in warning | critical) ;; *) exit 0 ;; esac
      headers+=("Rate-limit checkpoint: $due_name $due_band band ($due_percentage%), resets $due_label.")
      ;;
    "line$tab"*) readings+=("${record#line"$tab"}") ;;
    "marker$tab"*) marker_body="${record#marker"$tab"}" ;;
  esac
done <<<"$report"
[ "${#headers[@]}" -gt 0 ] || exit 0
[ -n "$marker_body" ] || exit 0

# JSON string encoding, one short line at a time. Every line already holds only
# letters, digits, spaces and `%():,./_-`; the escapes are defensive, backslash
# first so no later escape is doubled. Lines join with the two-character escape
# `\n`, never a raw newline.
text=""
for text_line in ${headers[@]+"${headers[@]}"} ${readings[@]+"${readings[@]}"} "$policy_line"; do
  text_line=${text_line//\\/\\\\}
  text_line=${text_line//\"/\\\"}
  text_line=${text_line//$tab/ }
  text="$text$text_line\\n"
done
text="${text%\\n}"
[ "${#text}" -le "$maximum_text_bytes" ] || exit 0

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$text"

if [ -d "$marker_directory" ] || mkdir -p "$marker_directory"; then
  temporary_marker="$marker.tmp.$$"
  if printf '%s\n' "$marker_body" >"$temporary_marker"; then
    mv -f "$temporary_marker" "$marker" || rm -f "$temporary_marker"
  else
    rm -f "$temporary_marker"
  fi
fi
exit 0
