#!/usr/bin/env bash
# shellcheck shell=bash
#
# UserPromptSubmit hook: record a maintainer's typed grant that lets one
# approved security row of the branch's test-design table past the security-row
# merge gate (test-design-merge-gate.sh) and the status post's same check. It
# records only when ALL of these hold, and says so out loud when it declines (a
# silent decline reads as a recorded grant):
#
#   1. The whole submitted prompt, trimmed of edge whitespace, is exactly
#      `test-row-grant <row id>`. A line inside longer text is refused, so no
#      copied, quoted or generated text ever grants.
#   2. The session is interactive (gaia_loop_session_is_interactive, the same
#      two-witness check the audit loop's grant recorder uses): a nested
#      `claude -p` that Claude's Bash tool starts loads these hooks too.
#   3. The payload cwd's branch resolves to exactly one plan run with a
#      TEST-DESIGN marker carrying approved_sha256, whose approved copy holds
#      that row with a security flag other than `none`.
#
# The grant lands in <main>/.gaia/local/protected/audit-loop/<B>.d/
# test-row-grants.json, written under the branch's audit-loop lock. The
# protected folder is denied to every Claude write by block-audit-loop-write.sh,
# so only this hook and a human write it. Each grant records the marker's
# approved_sha256 and counts only against that approved table.
#
# Invoked with arguments, with no payload, or with a payload naming the keyword
# for another event, it exits 1 and records nothing. A prompt that never
# mentions the keyword exits 0 before any jq or git call. Never exit 2: that
# blocks the prompt and erases it. Bash 3.2.

set -u

_tg_escape_json() {
  local text="${1-}"
  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  text="${text//$'\n'/\\n}"
  text="${text//$'\t'/\\t}"
  text="${text//$'\r'/ }"
  text="${text//[[:cntrl:]]/ }"
  printf '%s' "$text"
}

# _tg_say <message> [claude context]: systemMessage reaches only the person,
# additionalContext only Claude, which would otherwise report a grant that was
# never recorded.
_tg_say() {
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' \
    "$(_tg_escape_json "$1")" \
    "$(_tg_escape_json "${2:-$1 Claude: no test-row grant was recorded. Do not say it was recorded; tell the person why and what to do next.}")"
}

if [ "$#" -gt 0 ]; then
  printf 'test-row-grant: records only from a UserPromptSubmit payload on stdin; nothing recorded\n' >&2
  exit 1
fi

payload=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' payload || true
fi
if [ -z "$payload" ]; then
  printf 'test-row-grant: no UserPromptSubmit payload on stdin; nothing recorded\n' >&2
  exit 1
fi

case "$payload" in
  *test-row-grant*) ;;
  *) exit 0 ;;
esac

case "$payload" in
  *'"hook_event_name":"UserPromptSubmit"'* | *'"hook_event_name": "UserPromptSubmit"'*) ;;
  *)
    printf 'test-row-grant: payload is not a UserPromptSubmit event; nothing recorded\n' >&2
    exit 1
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  _tg_say "The test-row grant could not be recorded because jq is missing. Install jq and type the line again."
  exit 0
fi

prompt="$(printf '%s' "$payload" | jq -r '.prompt // "" | strings' 2>/dev/null)" || prompt=""
whitespace=$' \t\r\n'
edge="${prompt%%[!"$whitespace"]*}"
prompt="${prompt#"$edge"}"
edge="${prompt##*[!"$whitespace"]}"
prompt="${prompt%"$edge"}"
row=""
if [[ "$prompt" =~ ^test-row-grant\ (T[1-9][0-9]{0,5})$ ]]; then
  row="${BASH_REMATCH[1]}"
else
  case "$prompt" in
    *test-row-grant*)
      malformed_message="Not recorded: the whole prompt must be exactly test-row-grant <row id> (for example test-row-grant T7), with nothing else in the message."
      _tg_say "$malformed_message" "$malformed_message Claude: no test-row grant was recorded. If the person was only mentioning the line, answer them normally; otherwise tell them this."
      ;;
  esac
  exit 0
fi

_tg_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _tg_root=''
_tg_scripts="$_tg_root/.gaia/scripts"
if [ -z "$_tg_root" ] || [ ! -f "$_tg_scripts/audit-loop-state-lib.sh" ] || [ ! -f "$_tg_scripts/test-design/plan-locate-lib.sh" ]; then
  _tg_say "Not recorded: the GAIA libraries this grant needs were not found next to this hook."
  exit 0
fi
# shellcheck source=/dev/null
. "$_tg_scripts/audit-loop-state-lib.sh"
# shellcheck source=/dev/null
. "$_tg_scripts/test-design/plan-locate-lib.sh"

# One jq read for the three remaining fields, NUL-separated so a path keeps
# any byte; a field that is absent or not a string reads as empty.
transcript=""
session_id=""
cwd=""
{ IFS= read -r -d '' transcript && IFS= read -r -d '' session_id && IFS= read -r -d '' cwd; } < <(
  printf '%s' "$payload" | jq -j '[.transcript_path, .session_id, .cwd] | map(if type == "string" then . else "" end) | .[] + "\u0000"' 2>/dev/null
) || true
interactive_status=0
gaia_loop_session_is_interactive "$transcript" || interactive_status=$?
case "$interactive_status" in
  0) ;;
  2)
    _tg_say "Not recorded: the transcript has no record yet to show this session is interactive, as on a session's first prompt. Send any other message first, then type the line again."
    exit 0
    ;;
  *)
    _tg_say "Not recorded: this session is not interactive. In a Claude Code terminal session in the branch's checkout, send any message, then type the line."
    exit 0
    ;;
esac

case "$cwd" in /*) ;; *) cwd="" ;; esac
tree=""
main=""
key=""
branch=""
if [ -n "$cwd" ]; then
  tree="$(gaia_resolve_tree_root "$cwd" 2>/dev/null)" || tree=""
fi
if [ -n "$tree" ]; then
  main="$(gaia_resolve_main_root "$tree" 2>/dev/null)" || main=""
  key="$(gaia_loop_key "$tree" 2>/dev/null)" || key=""
  branch="$(_gaia_loop_git -C "$tree" branch --show-current 2>/dev/null)" || branch=""
fi
if [ -z "$main" ] || [ -z "$key" ] || [ -z "$branch" ]; then
  _tg_say "Not recorded: the session's working directory does not resolve to a checkout on a named branch."
  exit 0
fi

locate_status=0
plan="$(gaia_plan_folder_for_branch "$main" "$branch")" || locate_status=$?
if [ "$locate_status" -ne 0 ]; then
  if [ "$locate_status" -eq 2 ]; then
    _tg_say "Not recorded: more than one plan run claims branch $branch."
  else
    _tg_say "Not recorded: no plan run claims branch $branch."
  fi
  exit 0
fi
approved_sha=""
[ -f "$plan/TEST-DESIGN" ] && approved_sha="$(gaia_marker_approved_sha256 "$plan")"
if [ -z "$approved_sha" ]; then
  _tg_say "Not recorded: the plan run for branch $branch has no approved test-design table."
  exit 0
fi
security="$(jq -r --arg row "$row" '[.rows[] | select(.id == $row) | .security] | if length == 1 then .[0] else "" end | strings' "$plan/tests.approved.json" 2>/dev/null)" || security=""
case "$security" in
  "" )
    _tg_say "Not recorded: the approved test-design table for branch $branch has no row $row."
    exit 0
    ;;
  none)
    _tg_say "Not recorded: row $row is not a security row, so the security-row merge gate never holds it."
    exit 0
    ;;
esac

grants_file="$(gaia_test_row_grants_file "$main" "$key")"
lock_target="$(gaia_loop_state_file "$main" "$key")"
if ! gaia_loop_lock "$lock_target" "$(($(date +%s) + 5))"; then
  _tg_say "Not recorded: the branch's audit state is locked by another writer. Retry the line in a moment."
  exit 0
fi
existing='{"grants":[]}'
if [ -e "$grants_file" ]; then
  existing="$(jq -c 'select((.grants | type) == "array")' "$grants_file" 2>/dev/null)" || existing=""
  if [ -z "$existing" ]; then
    gaia_loop_unlock "$lock_target"
    _tg_say "Not recorded: the grant file $grants_file is unreadable. A human must repair it or move it aside outside Claude; it was left untouched."
    exit 0
  fi
fi
at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
new="$(printf '%s' "$existing" | jq -c --arg row "$row" --arg sha "$approved_sha" --arg at "$at" --arg session_id "$session_id" \
  '.grants += [{row: $row, approved_sha256: $sha, at: $at, session_id: $session_id}]' 2>/dev/null)" || new=""
written=0
if [ -n "$new" ] && mkdir -p "${grants_file%/*}" 2>/dev/null; then
  temporary_file="$grants_file.tmp.$$"
  if printf '%s\n' "$new" >"$temporary_file" 2>/dev/null && mv -f "$temporary_file" "$grants_file" 2>/dev/null; then
    written=1
  else
    rm -f "$temporary_file"
  fi
fi
gaia_loop_unlock "$lock_target"
if [ "$written" -ne 1 ]; then
  _tg_say "Not recorded: the grant file could not be written. Retry the line."
  exit 0
fi
recorded_message="Recorded: test-row-grant $row on branch $branch. The security-row merge gate and the status post now let row $row through while the approved table is unchanged."
_tg_say "$recorded_message" "$recorded_message Claude: the human typed this line."
exit 0
