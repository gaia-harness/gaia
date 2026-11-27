# shellcheck shell=bash
#
# The any-age context reader and the session save target, split from
# context-checkpoint-lib.sh to keep that lib under the line limit.
#
# Owns: gaia_context_read_any_age (the reading of a session whatever its age,
# for a reader that treats an old reading from the same session as still
# valid, since context only grows within a session, except after compaction)
# and gaia_context_session_save_path (the one definition of a session's checkpoint
# save target). The parse stays beside gaia_context_read in the checkpoint lib.
#
# Sourcing defines functions only and runs no external command. Bash 3.2
# compatible, never `cd`s, and has no `set -e`. Double-sourcing is a no-op.

[ -n "${_GAIA_CONTEXT_ANY_AGE_LIBRARY_LOADED:-}" ] && return 0
_GAIA_CONTEXT_ANY_AGE_LIBRARY_LOADED=1

_gaia_context_any_age_directory="${BASH_SOURCE[0]%/*}"
[ "$_gaia_context_any_age_directory" = "${BASH_SOURCE[0]}" ] && _gaia_context_any_age_directory="."
# shellcheck source=/dev/null
. "$_gaia_context_any_age_directory/context-checkpoint-lib.sh" || return 2

# gaia_context_read_any_age <main-root> <session_id> <now-epoch>: print
# "<used_tokens> <window_size>" and return 0 for a valid reading of any age; rc 1
# with no stdout when it is missing, unparseable or in the future.
# shellcheck disable=SC2154 # the reading variables are set by _gaia_context_parse_reading
gaia_context_read_any_age() {
  _gaia_context_parse_reading "${1:-}" "${2:-}" "${3:-}" || return 1
  printf '%s %s\n' "$_gaia_context_reading_used" "$_gaia_context_reading_window"
}

# gaia_context_session_save_path <main-root> <session_id>: print the file a
# session's checkpoint saves to; rc 1 with no stdout for a non-UUID id.
gaia_context_session_save_path() {
  gaia_context_is_session_id "${2:-}" || return 1
  printf '%s/.gaia/local/runs/session-%s/STATE.md\n' "${1:-}" "$2"
}
