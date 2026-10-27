#!/usr/bin/env bash
# shellcheck shell=bash
#
# GAIA dev-server process library: listener discovery, process identity,
# owning-tree attribution, verified stops, and the launch and session records
# that let a later session stop servers an ended Claude session left running.
# Dual-mode: source it for the functions below, or run it for the CLI at the
# bottom. Bash 3.2 safe, BSD and GNU tools, no `set -e`.
#
# Every automated signal GAIA sends to a dev server it did not launch itself
# goes through this file, and a wrong match stops another session's or a
# human's server. So the rule here is "refuse, do not guess": this is a
# per-tree reaper, and an identity it cannot establish with positive evidence
# is a reason to do nothing.
#
# Process backend, chosen by GAIA_PORTS_PROCESS_PROBE (`auto`, the default,
# `lsof`, or `proc`): `lsof` reads listeners and working directories on macOS
# and Linux alike; `proc` reads listeners from `ss` and working directories
# from /proc/<pid>/cwd on Linux. `auto` prefers `lsof` and falls back to
# `proc` where /proc exists. With neither, listener discovery returns 3,
# ownership answers `unknown`, and nothing is ever stopped.
#
# Listener discovery sees only processes the caller may inspect: an
# unprivileged `lsof` lists the caller's own processes, and `ss` omits the
# owning PID of another user's socket (reported here as PID 0, which no stop
# ever signals).
#
# State lives under the main-anchored ports directory (one file per record, so
# a reaper deletes with `rm` and never rewrites a shared file; this library
# takes no lock):
#   launches/<pid>.tsv     pid, start, command, cwd, port, kind, session id,
#                          host pid, host start, tree root
#   sessions/<id>.tsv      host pid, host start, host command, registered epoch
#   tombstones/*.tsv       slot, tree root, reclaimed epoch (written elsewhere)
#   slots.tsv              slot, tree root, tree marker (read here, never written)
#
# Test seams (not adopter tuning): GAIA_PORTS_PROCESS_PROBE,
# GAIA_PORTS_HOST_PID, GAIA_PORTS_STATE_DIRECTORY, GAIA_PORTS_DEV_BASE_PORT,
# GAIA_PORTS_STORYBOOK_BASE_PORT.
#
# Usage (executable):
#   bash .gaia/scripts/server-process-lib.sh --listener-owner <port> <tree-root>
#   bash .gaia/scripts/server-process-lib.sh --record-launch --pid <pid> \
#     --port <port> --kind <dev|storybook> --tree <tree-root>
#   bash .gaia/scripts/server-process-lib.sh --listeners <port>...
# Exit 0 except usage errors (2).

_gaia_server_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
# shellcheck source=main-root-lib.sh
. "$_gaia_server_library_directory/main-root-lib.sh"

_gaia_server_tab=$'\t'
_gaia_server_tombstone_expiry_seconds=$((7 * 24 * 60 * 60))
_gaia_server_stop_wait_tenths=30
_gaia_server_ancestry_step_limit=64

# shellcheck source=server-process-discovery.sh
. "$_gaia_server_library_directory/server-process-discovery.sh"
# shellcheck source=server-process-stop.sh
. "$_gaia_server_library_directory/server-process-stop.sh"
# shellcheck source=server-process-sessions.sh
. "$_gaia_server_library_directory/server-process-sessions.sh"

_gaia_server_diagnostic() {
  printf 'GAIA server-process: %s\n' "$*" >&2
}

_gaia_server_is_integer() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

_gaia_server_is_port() {
  _gaia_server_is_integer "$1" || return 1
  [ "${#1}" -le 5 ] || return 1
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

_gaia_server_is_session_id() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

# Strip one or more trailing slashes, keeping a bare `/`.
_gaia_server_strip_trailing_slash() {
  local path="$1"
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  printf '%s' "$path"
}

# Physical path of an existing directory, else the argument unchanged (a
# removed tree has nothing left to resolve).
_gaia_server_physical_or_literal() {
  local path resolved
  path="$(_gaia_server_strip_trailing_slash "$1")"
  if [ -d "$path" ] && resolved="$(cd -P "$path" 2>/dev/null && pwd -P)" && [ -n "$resolved" ]; then
    printf '%s' "$resolved"
  else
    printf '%s' "$path"
  fi
}

# rc 0 when $1 is $2 or sits below it, on a path-segment boundary, so a tree
# at /x/tree never claims /x/tree-2.
_gaia_server_path_is_under() {
  local path="$1" root
  root="$(_gaia_server_strip_trailing_slash "$2")"
  [ -n "$root" ] || return 1
  [ "$path" = "$root" ] && return 0
  [ "$root" = "/" ] && return 0
  case "$path" in
    "$root"/*) return 0 ;;
  esac
  return 1
}

# The inode of a path, GNU stat first: BSD rejects `-c`, while GNU accepts
# `-f` as "filesystem status" and would print the wrong number.
_gaia_server_inode() {
  local inode
  inode="$(stat -c %i "$1" 2>/dev/null)" || inode=""
  if ! _gaia_server_is_integer "$inode"; then
    inode="$(stat -f %i "$1" 2>/dev/null)" || inode=""
  fi
  _gaia_server_is_integer "$inode" || return 1
  printf '%s' "$inode"
}

# Prints the backend for a capability (`listeners` or `cwds`): lsof, proc, or
# none.
_gaia_server_backend() {
  local capability="$1" requested="${GAIA_PORTS_PROCESS_PROBE:-auto}"
  local lsof_available=0 proc_available=0
  command -v lsof >/dev/null 2>&1 && lsof_available=1
  if [ -e /proc/self ]; then
    if [ "$capability" = "listeners" ]; then
      command -v ss >/dev/null 2>&1 && proc_available=1
    else
      proc_available=1
    fi
  fi
  case "$requested" in
    lsof)
      [ "$lsof_available" -eq 1 ] && { printf 'lsof'; return 0; }
      ;;
    proc)
      [ "$proc_available" -eq 1 ] && { printf 'proc'; return 0; }
      ;;
    auto)
      [ "$lsof_available" -eq 1 ] && { printf 'lsof'; return 0; }
      [ "$proc_available" -eq 1 ] && { printf 'proc'; return 0; }
      ;;
    *)
      _gaia_server_diagnostic "unrecognized GAIA_PORTS_PROCESS_PROBE '$requested' (expected auto, lsof, or proc); no backend used"
      ;;
  esac
  printf 'none'
}

# rc 0 when the port is in the space-separated list.
_gaia_server_port_listed() {
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Resolves the ports state directory for the CLI: the seam, else
# <main-root>/.gaia/local/ports for the given directory.
_gaia_server_state_directory() {
  local main_root
  if [ -n "${GAIA_PORTS_STATE_DIRECTORY:-}" ]; then
    printf '%s' "$GAIA_PORTS_STATE_DIRECTORY"
    return 0
  fi
  main_root="$(gaia_resolve_main_root "${1:-}" 2>/dev/null)" || return 1
  [ -n "$main_root" ] || return 1
  printf '%s/.gaia/local/ports' "$main_root"
}

_gaia_server_usage() {
  {
    printf 'usage: server-process-lib.sh --listener-owner <port> <tree-root>\n'
    printf '       server-process-lib.sh --record-launch --pid <pid> --port <port> --kind <dev|storybook> --tree <tree-root>\n'
    printf '       server-process-lib.sh --listeners <port>...\n'
  } >&2
  return 2
}

_gaia_server_main() {
  case "${1:-}" in
    --listener-owner)
      [ "$#" -eq 3 ] || { _gaia_server_usage; return 2; }
      _gaia_server_is_port "$2" || { _gaia_server_usage; return 2; }
      [ -n "$3" ] || { _gaia_server_usage; return 2; }
      gaia_server_listener_owner "$2" "$3"
      return 0
      ;;
    --listeners)
      shift
      [ "$#" -ge 1 ] || { _gaia_server_usage; return 2; }
      local port
      for port in "$@"; do
        _gaia_server_is_port "$port" || { _gaia_server_usage; return 2; }
      done
      gaia_server_listeners "$@" || _gaia_server_diagnostic "no process backend available (lsof, or ss with /proc)"
      return 0
      ;;
    --record-launch)
      shift
      local pid="" port="" kind="" tree_root=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --pid | --port | --kind | --tree)
            [ "$#" -ge 2 ] || { _gaia_server_usage; return 2; }
            case "$1" in
              --pid) pid="$2" ;;
              --port) port="$2" ;;
              --kind) kind="$2" ;;
              --tree) tree_root="$2" ;;
            esac
            shift 2
            ;;
          *)
            _gaia_server_usage
            return 2
            ;;
        esac
      done
      _gaia_server_is_integer "$pid" && [ "$pid" -gt 1 ] || { _gaia_server_usage; return 2; }
      _gaia_server_is_port "$port" || { _gaia_server_usage; return 2; }
      case "$kind" in dev | storybook) ;; *) _gaia_server_usage; return 2 ;; esac
      case "$tree_root" in /*) ;; *) _gaia_server_usage; return 2 ;; esac
      local state_directory
      state_directory="$(_gaia_server_state_directory "$tree_root")" || {
        _gaia_server_diagnostic "record launch: ports state directory unresolvable; not recorded"
        return 0
      }
      gaia_server_record_launch "$state_directory" "$pid" "$port" "$kind" "$tree_root" || true
      return 0
      ;;
    *)
      _gaia_server_usage
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _gaia_server_main "$@"
  exit $?
fi
