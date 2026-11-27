# shellcheck shell=bash
#
# The picker's hand-off skip. The bound hook records a checkpoint with
# `handoff: true` and the session's id when the context line is reached, and
# the job it ends is meant to continue in a fresh session. A /loop re-runs the
# picker in the same session, so whenever the band handoff below does not
# answer first (the reading dropped below the line after a compaction, or there
# is no usable reading) it skips the branch and takes other work; any other
# session picks it up with no answer.
#
# The band handoff: before any queue tier, a session whose own context reading
# (any age: context only grows within a session, except after compaction) is
# at the red band or past it is handed a `handoff` object instead of a job.
#
# Reads only. Every unknown (no session id, an absent, corrupt or unkeyable
# state) is no skip and no handoff: the picker never hides work it cannot
# account for.

_gaia_next_handoff_directory="${BASH_SOURCE[0]%/*}"
[ "$_gaia_next_handoff_directory" = "${BASH_SOURCE[0]}" ] && _gaia_next_handoff_directory="."
# shellcheck source=/dev/null
. "$_gaia_next_handoff_directory/audit-loop-state-lib.sh" || return 2
# shellcheck source=/dev/null
. "$_gaia_next_handoff_directory/context-any-age-lib.sh" || return 2

# gaia_next_handoff_skip <main-root> <branch>: rc 0 when the branch's pending
# checkpoint is a hand-off recorded by this session, else rc 1.
gaia_next_handoff_skip() {
  local main_root="${1-}" branch_key state_json checkpoint_json
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 1
  branch_key="$(gaia_branch_normalize "${2-}")"
  _gaia_loop_keyable "$branch_key" || return 1
  state_json="$(gaia_loop_read_state "$(gaia_loop_state_file "$main_root" "$branch_key")")" || return 1
  checkpoint_json="$(gaia_loop_pending_checkpoint "$state_json")"
  [ -n "$checkpoint_json" ] || return 1
  printf '%s' "$checkpoint_json" | jq -e --arg session "$CLAUDE_CODE_SESSION_ID" \
    '.handoff == true and .session_id == $session' >/dev/null 2>&1
}

# gaia_next_band_handoff <main-root>: when this session's context is at the red
# band or past it, print the `handoff` job object, say so on stderr and return
# 0; every other case returns 1 with nothing printed.
gaia_next_band_handoff() {
  local main_root="${1-}" session_id="${CLAUDE_CODE_SESSION_ID:-}" now="${EPOCHSECONDS:-}"
  local reading used_tokens window line band save_path
  [ -n "$now" ] || now="$(date +%s)"
  reading="$(gaia_context_read_any_age "$main_root" "$session_id" "$now")" || return 1
  read -r used_tokens window <<<"$reading"
  line="$(gaia_context_effective_line "$main_root" "$window")" || return 1
  band="$(gaia_context_band "$used_tokens" "$window" "$line")" || return 1
  gaia_context_band_at_or_past_line "$band" || return 1
  save_path="$(gaia_context_session_save_path "$main_root" "$session_id")" || return 1
  jq -cn --arg band "$band" --argjson used_tokens "$used_tokens" --argjson window "$window" --arg save_path "$save_path" \
    '{job: "handoff", band: $band, used_tokens: $used_tokens, context_window_size: $window, save_path: $save_path}' || return 1
  printf 'gaia-next: context at the %s band (%s tokens); no new job this session\n' "$band" "$used_tokens" >&2
}
