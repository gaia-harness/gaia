#!/usr/bin/env bash
# shellcheck shell=bash
#
# UserPromptSubmit hook: record a human's answer to an audit checkpoint.
#
# At a checkpoint the audit loop stops and only a person may raise the
# allowance. The state file's `allowance` section has two writers: this hook,
# which records the typed lines, and audit-loop-ask-grant.sh, which records a
# selection of the question the bound hook pinned (see "Other channels"
# below). Nothing else, not the bound hook, the evaluator or any sub-agent,
# records a grant or an accept. This hook records one when ALL of these hold,
# and says so out loud when it declines (a silent decline reads as a recorded
# grant):
#
#   1. The whole submitted prompt is exactly the line `audit-grant <n>`,
#      `audit-accept` or `audit-accept-finding <n>`. A line pasted inside longer text, quoted in a question
#      or mentioned in passing is rejected, so no copied, quoted or generated
#      text ever grants. The grammar and its parser live in
#      audit-loop-state-lib.sh (gaia_loop_parse_line); this hook never
#      restates it.
#   2. A checkpoint is pending on the branch the session resolves to: the
#      branch of the payload cwd first, else the one non-closed branch whose
#      pending checkpoint was recorded by this same session (an orchestrator
#      audits a linked worktree from the main checkout, so the cwd branch is
#      not always the audited one). Because a checkpoint is answered once, a
#      second typed line finds nothing pending: a grant is once per
#      checkpoint, never a standing licence. Ambiguity records nothing.
#   3. The session is interactive. The hook's own environment must carry
#      CLAUDE_CODE_ENTRYPOINT=cli, and every transcript record that carries an
#      `entrypoint` field must hold `cli`. Claude's Bash tool can start a
#      nested `claude -p` session in the same checkout that loads these same
#      project hooks, with any prompt Claude likes: a fresh one reports
#      `sdk-cli` in its environment, and a resumed one (`claude -c -p`)
#      appends records whose entrypoint is not `cli` to the same transcript.
#      The UserPromptSubmit event alone is not proof a person typed the line.
#      A session's first prompt can fail this check too: until a record
#      carrying `entrypoint` is written, it is refused.
#
# Other channels. An AskUserQuestion selection is recorded only by
# audit-loop-ask-grant.sh, and only against a question the bound hook pinned
# whole in guarded state: Claude authors no option, so a selection is the
# pinned text and nothing else. Any other AskUserQuestion attests nothing and
# is never read here. A `!` command a user types and a command Claude's Bash
# tool runs are indistinguishable to a script, so neither can be trusted to
# carry the grant; only a submitted prompt, seen by this hook, can.
#
# The typed lines stay as the fallback and as the deliberate human override:
# a typed `audit-accept` is accepted whether or not the pinned question offered
# an accept option (it overrides the eligibility gate). A typed
# `audit-grant <n>` keeps its meaning (n more rounds) and the answer it
# writes carries `source: "typed"`.
#
# `audit-accept-finding <n>` accepts one fix the pending checkpoint's fixer
# refused, entry n of the `disputes` list the bound hook stored on that
# checkpoint, so the key comes from guarded state and never from the prompt or
# the run folder. It appends to `allowance.accepted_keys`, not `answers`, so the
# checkpoint stays unanswered and the grant fold never sees it. A critical
# entry is refused; a security-class one is recorded, and the dispositions
# check still keeps it on fix.
#
# Invoked with arguments, with no payload on stdin, or with a payload that
# mentions a keyword but is for an event other than UserPromptSubmit, the hook
# exits 1 and records nothing, so running it by hand or from a tool call cannot
# record anything either. A payload mentioning neither keyword exits 0 first.
#
# Cost. A prompt that mentions neither keyword exits 0 with no output before
# any jq or git call, using shell builtins only.
#
# Never exit 2: that blocks the prompt and erases it. Every decline exits 0
# (Claude Code shows stdout JSON only on exit 0) with the reason in both fields:
# `systemMessage` reaches only the person and `additionalContext` reaches only
# Claude, which otherwise reports a grant that was never recorded. Bash 3.2;
# never `cd`s outside the command substitution that locates the libraries.

set -u

# _gl_escape_json <text>: JSON string body, builtins only (works with jq absent).
_gl_escape_json() {
  local text="${1-}"
  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  text="${text//$'\n'/\\n}"
  text="${text//$'\t'/\\t}"
  text="${text//$'\r'/ }"
  text="${text//[[:cntrl:]]/ }"
  printf '%s' "$text"
}

_GL_NOTHING_RECORDED_FOR_CLAUDE="Claude: no grant or accept was recorded and the audit allowance is unchanged."

# _gl_say <message> [claude-context]: the UserPromptSubmit JSON response. With
# no context it is a decline, and Claude gets the message and what it means.
_gl_say() {
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' \
    "$(_gl_escape_json "$1")" \
    "$(_gl_escape_json "${2:-$1 $_GL_NOTHING_RECORDED_FOR_CLAUDE Do not say it was recorded, and do not dispatch another audit round on it. Tell the person why and what to do next.}")"
}

# Arguments mean someone is running the recorder by hand.
if [ "$#" -gt 0 ]; then
  printf 'audit-loop-grant: records only from a UserPromptSubmit payload on stdin; nothing recorded\n' >&2
  exit 1
fi

payload=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' payload || true
fi
if [ -z "$payload" ]; then
  printf 'audit-loop-grant: no UserPromptSubmit payload on stdin; nothing recorded\n' >&2
  exit 1
fi

# Cheap exit: neither keyword anywhere in the payload.
case "$payload" in
  *audit-grant* | *audit-accept*) ;;
  *) exit 0 ;;
esac

# Event check without jq: the payload must be a UserPromptSubmit.
case "$payload" in
  *'"hook_event_name":"UserPromptSubmit"'* | *'"hook_event_name": "UserPromptSubmit"'*) ;;
  *)
    printf 'audit-loop-grant: payload is not a UserPromptSubmit event; nothing recorded\n' >&2
    exit 1
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  _gl_say "The audit line could not be recorded because jq is missing. Install jq and type the line again."
  exit 0
fi

_gl_hook_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _gl_hook_root=''
_gl_scripts="$_gl_hook_root/.gaia/scripts"
if [ -z "$_gl_hook_root" ] || [ ! -f "$_gl_scripts/audit-loop-state-lib.sh" ] || [ ! -f "$_gl_scripts/audit-loop-eval.sh" ]; then
  _gl_say "The audit line could not be recorded: the audit loop libraries were not found next to this hook. Nothing recorded."
  exit 0
fi
# shellcheck source=/dev/null
. "$_gl_scripts/main-root-lib.sh"
# shellcheck source=/dev/null
. "$_gl_scripts/audit-loop-state-lib.sh"
# shellcheck source=/dev/null
. "$_gl_scripts/audit-loop-eval.sh"

prompt="$(printf '%s' "$payload" | jq -r '.prompt // "" | strings' 2>/dev/null)" || prompt=""
parsed="$(gaia_loop_parse_line "$prompt")"
case "$parsed" in
  none) exit 0 ;;
  malformed)
    gline="$(gaia_loop_grant_line 1)"
    gline="${gline% 1} <n>"
    malformed_message="Not recorded: the whole prompt must be exactly $gline (n from 1 to 10), exactly $(gaia_loop_accept_line), or exactly audit-accept-finding <n> (n from the checkpoint's list), with nothing else in the message."
    _gl_say "$malformed_message" "$malformed_message $_GL_NOTHING_RECORDED_FOR_CLAUDE If the person was only mentioning the line, answer them normally; otherwise tell them this."
    exit 0
    ;;
esac

# Interactive check.
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // "" | strings' 2>/dev/null)" || transcript=""
interactive_exit_status=0
gaia_loop_session_is_interactive "$transcript" || interactive_exit_status=$?
case "$interactive_exit_status" in
  0) ;;
  2)
    printf 'audit-loop-grant: no transcript record yet; nothing recorded\n' >&2
    _gl_say "Not recorded: the transcript has no record yet to show this session is interactive, as on a session's first prompt. Send any other message first, then type the line again."
    exit 0
    ;;
  *)
    printf 'audit-loop-grant: session is not interactive; nothing recorded\n' >&2
    _gl_say "Not recorded: this session is not interactive, and --continue or --resume of it stays that way. In a new Claude Code terminal session in the audited branch's checkout, send any message, then type the line."
    exit 0
    ;;
esac

session_id="$(printf '%s' "$payload" | jq -r '.session_id // "" | strings' 2>/dev/null)" || session_id=""
cwd="$(printf '%s' "$payload" | jq -r '.cwd // "" | strings' 2>/dev/null)" || cwd=""
case "$cwd" in
  /*) ;;
  *) cwd="" ;;
esac
main=""
if [ -n "$cwd" ]; then
  main="$(gaia_resolve_main_root "$cwd" 2>/dev/null)" || main=""
fi
if [ -z "$main" ]; then
  _gl_say "Not recorded: the session's working directory does not resolve to a git checkout, so no audit state was found."
  exit 0
fi

branch=""
branch="$(gaia_loop_key "$cwd" 2>/dev/null)" || branch=""

_gl_corrupt() {
  _gl_say "Not recorded: the audit state file $1 is corrupt. A human must repair it outside Claude (restore a valid copy, or move it aside with mv to start the branch fresh); it was left untouched."
}

target=""
state=""
pending=""
if [ -n "$branch" ]; then
  candidate_state_file="$(gaia_loop_state_file "$main" "$branch")"
  state="$(gaia_loop_read_state "$candidate_state_file" 2>/dev/null)"
  state_read_exit_status=$?
  if [ "$state_read_exit_status" -eq 5 ]; then
    _gl_corrupt "$candidate_state_file"
    exit 0
  fi
  if [ "$state_read_exit_status" -eq 0 ]; then
    pending="$(gaia_loop_pending_checkpoint "$state")"
    [ -n "$pending" ] && target="$candidate_state_file"
  fi
fi

if [ -z "$target" ]; then
  matches=0
  statedir="$main/.gaia/local/protected/audit-loop"
  if [ -n "$session_id" ] && [ -d "$statedir" ]; then
    while IFS= read -r candidate_state_file; do
      candidate_state="$(gaia_loop_read_state "$candidate_state_file" 2>/dev/null)" || continue
      candidate_pending_checkpoint="$(gaia_loop_pending_checkpoint "$candidate_state")"
      [ -n "$candidate_pending_checkpoint" ] || continue
      candidate_session_id="$(printf '%s' "$candidate_pending_checkpoint" | jq -r '.session_id // "" | strings' 2>/dev/null)" || candidate_session_id=""
      if [ "$candidate_session_id" = "$session_id" ]; then
        matches=$((matches + 1))
        target="$candidate_state_file"
      fi
    done < <(find "$statedir" -name .closed -prune -o -type f -name '*.json' -print 2>/dev/null)
  fi
  if [ "$matches" -ne 1 ]; then
    _gl_say "Not recorded: no audit checkpoint is pending on branch ${branch:-(none)} for this session; type the line in the session whose dispatch hit the checkpoint."
    exit 0
  fi
fi

# Record under the lock, re-reading after acquiring it.
if ! gaia_loop_lock "$target" "$(($(date +%s) + 5))"; then
  _gl_say "Not recorded: the audit state file is locked by another writer. Retry the line in a moment."
  exit 0
fi
state="$(gaia_loop_read_state "$target" 2>/dev/null)"
state_read_exit_status=$?
if [ "$state_read_exit_status" -ne 0 ]; then
  gaia_loop_unlock "$target"
  if [ "$state_read_exit_status" -eq 5 ]; then
    _gl_corrupt "$target"
  else
    _gl_say "Not recorded: the audit state file $target could not be read."
  fi
  exit 0
fi
pending="$(gaia_loop_pending_checkpoint "$state")"
if [ -z "$pending" ]; then
  gaia_loop_unlock "$target"
  _gl_say "Not recorded: no audit checkpoint is pending on branch ${branch:-(none)} for this session; type the line in the session whose dispatch hit the checkpoint."
  exit 0
fi
checkpoint_index="$(printf '%s' "$pending" | jq -r '.index')"
at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
case "$parsed" in
  "accept-finding "*)
    finding_number="${parsed#accept-finding }"
    finding="$(printf '%s' "$pending" | jq -c --argjson finding_number "$finding_number" '(.disputes // [])[$finding_number - 1] // empty
      | select((.member | type) == "string" and (.finding_class | type) == "string" and (.path | type) == "string" and (.line | type) == "number")' 2>/dev/null)" || finding=""
    refusal=""
    if [ -z "$finding" ]; then
      refusal="Not recorded: checkpoint $checkpoint_index lists no refused fix numbered $finding_number."
    elif [ "$(printf '%s' "$finding" | jq -r '.severity // ""')" = critical ]; then
      refusal="Not recorded: refused fix $finding_number is critical, and a critical finding is always fixed."
    fi
    if [ -n "$refusal" ]; then
      gaia_loop_unlock "$target"
      _gl_say "$refusal"
      exit 0
    fi
    new="$(printf '%s' "$state" | jq -c --argjson checkpoint_number "$checkpoint_index" --argjson finding "$finding" --arg at "$at" --arg session_id "$session_id" \
      '.allowance.accepted_keys = ((.allowance.accepted_keys // []) + [{checkpoint: $checkpoint_number, key: ($finding | [.member, .finding_class, .path, .line]),
        source: "typed", at: $at, session_id: $session_id}])' 2>/dev/null)" || new=""
    ;;
  "grant "*)
    granted_round_count="${parsed#grant }"
    new="$(printf '%s' "$state" | jq -c --argjson checkpoint_number "$checkpoint_index" --argjson granted_round_count "$granted_round_count" --arg at "$at" --arg session_id "$session_id" \
      '.allowance.answers += [{checkpoint: $checkpoint_number, kind: "grant", n: $granted_round_count, source: "typed", at: $at, session_id: $session_id}]' 2>/dev/null)" || new=""
    ;;
  *)
    new="$(printf '%s' "$state" | jq -c --argjson checkpoint_number "$checkpoint_index" --arg at "$at" --arg session_id "$session_id" \
      '.allowance.answers += [{checkpoint: $checkpoint_number, kind: "accept", source: "typed", at: $at, session_id: $session_id}]' 2>/dev/null)" || new=""
    ;;
esac
if [ -z "$new" ] || ! gaia_loop_write_state "$target" "$new"; then
  gaia_loop_unlock "$target"
  _gl_say "Not recorded: the audit state file could not be written. Retry the line."
  exit 0
fi
gaia_loop_unlock "$target"

allowed="$(gaia_loop_allowed "$new")"
branch_name="$(printf '%s' "$new" | jq -r '.branch')"
case "$parsed" in
  "accept-finding "*)
    recorded_message="Recorded: audit-accept-finding $finding_number ($(printf '%s' "$finding" | jq -r '.path + ":" + (.line | tostring)')) on branch $branch_name (checkpoint $checkpoint_index). The round after this checkpoint may keep it as an accepted residual unless it is security-class. The checkpoint itself is still unanswered."
    _gl_say "$recorded_message" "$recorded_message Claude: the human typed this line. Ask the pinned checkpoint question again for its answer."
    exit 0
    ;;
  "grant "*)
    recorded_message="Recorded: $(gaia_loop_grant_line "$granted_round_count") on branch $branch_name (checkpoint $checkpoint_index). Rounds allowed through round $allowed."
    ;;
  *)
    recorded_message="Recorded: $(gaia_loop_accept_line) on branch $branch_name (checkpoint $checkpoint_index). Exactly one closing round is allowed (round $allowed) and no fixer runs in it."
    ;;
esac
_gl_say "$recorded_message" "$recorded_message Claude: the human typed this line; continue the loop within that allowance."
exit 0
