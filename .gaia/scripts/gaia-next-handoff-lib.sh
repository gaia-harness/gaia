# shellcheck shell=bash
#
# The picker's hand-off skip. The bound hook records a checkpoint with
# `handoff: true` and the session's id when the context line is reached, and
# the job it ends is meant to continue in a fresh session. A /loop re-runs the
# picker in the same over-the-line session, so that session skips the branch;
# any other session picks it up with no answer.
#
# Reads only. Every unknown (no session id, an absent, corrupt or unkeyable
# state) is no skip: the picker never hides work it cannot account for.

_gaia_next_handoff_directory="${BASH_SOURCE[0]%/*}"
[ "$_gaia_next_handoff_directory" = "${BASH_SOURCE[0]}" ] && _gaia_next_handoff_directory="."
# shellcheck source=/dev/null
. "$_gaia_next_handoff_directory/audit-loop-state-lib.sh" || return 2

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
