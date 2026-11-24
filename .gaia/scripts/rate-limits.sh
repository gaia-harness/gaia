#!/usr/bin/env bash
# The per-session rate-limit reading, from the command line.
#
#   rate-limits.sh read                           print one line per window, or
#                                                 `no reading`; always exits 0
#   rate-limits.sh write <session-id> '<json>'    write one session's reading
#                                                 through the library's writer;
#                                                 exits with its return code (0
#                                                 written or unchanged, 1 write
#                                                 failed, 2 invalid reading)
#
# `read` shows, per window, the reading of the session CLAUDE_CODE_SESSION_ID
# names (Claude Code exports it to Bash tool commands) when that session's file
# holds the window, else the reading whose figure changed most recently across
# sessions; a value that is not UUID-shaped reads as absent. `write` refuses a
# session id that is not UUID-shaped, since the id forms the file's path.
#
# Any other verb or argument count prints usage on stderr and exits 2. The
# main checkout comes from the working directory, so a linked worktree reads
# and writes the main checkout's files; outside a repository it falls back to
# this script's own checkout. GAIA_RATE_LIMITS_NOW and TZ pin the clock and the
# time zone.

set -uo pipefail

_rate_limits_script_directory="${BASH_SOURCE[0]%/*}"
[ "$_rate_limits_script_directory" = "${BASH_SOURCE[0]}" ] && _rate_limits_script_directory=.

_rate_limits_usage() {
  printf 'usage: bash .gaia/scripts/rate-limits.sh read\n       bash .gaia/scripts/rate-limits.sh write <session-id> <input-json>\n' >&2
}

_rate_limits_main_root() {
  local root=""
  # shellcheck source=.gaia/scripts/main-root-lib.sh
  if . "$_rate_limits_script_directory/main-root-lib.sh" 2>/dev/null; then
    root=$(gaia_resolve_main_root "$PWD" 2>/dev/null) || root=""
  fi
  if [ -z "$root" ]; then
    root=$(cd "$_rate_limits_script_directory/../.." 2>/dev/null && pwd -P) || root=""
  fi
  [ -n "$root" ] || return 1
  printf '%s\n' "$root"
}

_rate_limits_read() {
  local root now records line
  # shellcheck source=.gaia/scripts/rate-limits-lib.sh
  if . "$_rate_limits_script_directory/rate-limits-lib.sh" 2>/dev/null \
    && root=$(_rate_limits_main_root) \
    && now=$(gaia_rate_limits_now) \
    && records=$(gaia_rate_limits_report "$root" "$now" reader "${CLAUDE_CODE_SESSION_ID:-}") \
    && [ -n "$records" ]; then
    while IFS= read -r line; do
      case $line in
        line$'\t'*) printf '%s\n' "${line#line$'\t'}" ;;
      esac
    done <<<"$records"
    return 0
  fi
  printf 'no reading\n'
}

_rate_limits_write() {
  local root now
  # shellcheck source=.gaia/scripts/rate-limits-lib.sh
  . "$_rate_limits_script_directory/rate-limits-lib.sh" 2>/dev/null || {
    printf 'rate-limits: cannot load %s\n' "$_rate_limits_script_directory/rate-limits-lib.sh" >&2
    return 1
  }
  gaia_context_is_session_id "$1" || {
    _rate_limits_usage
    return 2
  }
  root=$(_rate_limits_main_root) || return 1
  now=$(gaia_rate_limits_now) || return 1
  gaia_rate_limits_write "$root" "$now" "$1" "$2" >/dev/null
}

case "${1-}" in
  read)
    [ $# -eq 1 ] || { _rate_limits_usage; exit 2; }
    _rate_limits_read
    exit 0
    ;;
  write)
    [ $# -eq 3 ] || { _rate_limits_usage; exit 2; }
    _rate_limits_write "$2" "$3"
    exit $?
    ;;
  *)
    _rate_limits_usage
    exit 2
    ;;
esac
