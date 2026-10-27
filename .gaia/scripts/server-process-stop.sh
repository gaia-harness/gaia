#!/usr/bin/env bash
# shellcheck shell=bash
#
# GAIA dev-server process library, stop half: verified stops, removed-tree
# listener stops, and the reaps of dead sessions and tombstones.
# Sourced only by server-process-lib.sh, whose header holds the contract,
# the state layout and the test seams. Defines functions; does no work at
# source time.

# shellcheck disable=SC2154  # constants and _gaia_server_record_* come from server-process-lib.sh and server-process-sessions.sh

# rc 0 when pid is this process, the subshell running this code, or any
# ancestor of either. Unreadable ancestry counts as an ancestor (refuse).
_gaia_server_is_caller_or_ancestor() {
  local target_pid="$1" walk_pid parent_pid step=0
  [ "$target_pid" = "$$" ] && return 0
  [ -n "${BASHPID:-}" ] && [ "$target_pid" = "$BASHPID" ] && return 0
  walk_pid="${BASHPID:-$$}"
  while [ "$step" -lt "$_gaia_server_ancestry_step_limit" ]; do
    parent_pid="$(ps -o ppid= -p "$walk_pid" 2>/dev/null)" || return 0
    parent_pid="${parent_pid//[!0-9]/}"
    _gaia_server_is_integer "$parent_pid" || return 0
    [ "$parent_pid" = "$target_pid" ] && return 0
    [ "$parent_pid" -le 1 ] && return 1
    walk_pid="$parent_pid"
    step=$((step + 1))
  done
  return 0
}

# rc 0 when every recorded field still matches the live process: start,
# command, a readable cwd under the prefix, and a listener on the port.
_gaia_server_identity_matches() {
  local pid="$1" expected_start="$2" expected_command="$3" cwd_prefix="$4" port="$5"
  local identity current_start current_command
  identity="$(gaia_server_process_identity "$pid")" || return 1
  current_start="${identity%%"$_gaia_server_tab"*}"
  current_command="${identity#*"$_gaia_server_tab"}"
  [ "$current_start" = "$expected_start" ] || return 1
  [ "$current_command" = "$expected_command" ] || return 1

  local cwd_line cwd_path cwd_state resolved_prefix
  cwd_line="$(gaia_server_process_cwds "$pid")"
  cwd_path="$(printf '%s' "$cwd_line" | cut -f2)"
  cwd_state="$(printf '%s' "$cwd_line" | cut -f3)"
  [ "$cwd_state" = "live" ] || [ "$cwd_state" = "deleted" ] || return 1
  resolved_prefix="$(_gaia_server_physical_or_literal "$cwd_prefix")"
  _gaia_server_path_is_under "$cwd_path" "$cwd_prefix" || _gaia_server_path_is_under "$cwd_path" "$resolved_prefix" || return 1

  local listeners listener_port listener_pid listening=0
  listeners="$(gaia_server_listeners "$port")" || return 1
  while IFS="$_gaia_server_tab" read -r listener_port listener_pid; do
    [ "$listener_pid" = "$pid" ] && listening=1
  done <<EOF
$listeners
EOF
  [ "$listening" -eq 1 ]
}

# Polls up to the given tenths of a second for the pid to exit. rc 0 gone.
_gaia_server_wait_for_exit() {
  local pid="$1" tenths="$2" waited=0
  while [ "$waited" -lt "$tenths" ]; do
    _gaia_server_pid_alive "$pid" || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  _gaia_server_pid_alive "$pid" && return 1
  return 0
}

# Public names for the liveness checks above, for callers that reap a process
# they launched themselves.
gaia_server_pid_alive() { _gaia_server_pid_alive "$1"; }
gaia_server_wait_for_exit() { _gaia_server_wait_for_exit "$1" "$2"; }

# gaia_server_stop_verified <pid> <start> <command> <cwd-prefix> <port>:
# re-reads every field immediately before each signal and skips on any
# mismatch. SIGTERM, a bounded wait, re-verify, SIGKILL only if still
# matching. Never signals pid <= 1, the caller, or an ancestor of the caller.
# rc 0 stopped, 1 skipped, 2 already gone.
gaia_server_stop_verified() {
  local pid="$1" expected_start="$2" expected_command="$3" cwd_prefix="$4" port="$5"
  if ! _gaia_server_is_integer "$pid" || [ "$pid" -le 1 ]; then
    _gaia_server_diagnostic "refusing to signal pid '$pid'"
    return 1
  fi
  if _gaia_server_is_caller_or_ancestor "$pid"; then
    _gaia_server_diagnostic "refusing to signal pid $pid: it is this process or one of its ancestors"
    return 1
  fi
  if ! _gaia_server_is_port "$port" || [ -z "$expected_start" ] || [ -z "$expected_command" ] || [ -z "$cwd_prefix" ]; then
    _gaia_server_diagnostic "refusing to signal pid $pid: incomplete identity"
    return 1
  fi
  _gaia_server_pid_alive "$pid" || return 2
  _gaia_server_identity_matches "$pid" "$expected_start" "$expected_command" "$cwd_prefix" "$port" || return 1

  kill -TERM "$pid" 2>/dev/null || {
    _gaia_server_pid_alive "$pid" || return 0
    _gaia_server_diagnostic "SIGTERM to pid $pid failed"
    return 1
  }
  _gaia_server_wait_for_exit "$pid" "$_gaia_server_stop_wait_tenths" && return 0

  if ! _gaia_server_identity_matches "$pid" "$expected_start" "$expected_command" "$cwd_prefix" "$port"; then
    _gaia_server_diagnostic "pid $pid outlived SIGTERM and no longer matches its identity; not sending SIGKILL"
    return 1
  fi
  kill -KILL "$pid" 2>/dev/null || true
  _gaia_server_wait_for_exit "$pid" 10 && return 0
  _gaia_server_diagnostic "pid $pid survived SIGKILL"
  return 1
}

# Prints `<port>\t<pid>\t<start>\t<command>` for each listener on the ports
# that qualifies for a removed-tree stop: readable cwd under the tree root,
# no other tree nested between them, and the tree directory missing or the
# cwd deleted.
_gaia_server_removed_tree_candidates() {
  local tree_root tree_missing=0
  tree_root="$(_gaia_server_strip_trailing_slash "$1")"
  shift
  case "$tree_root" in
    /?*) ;;
    *) return 0 ;;
  esac
  [ -d "$tree_root" ] || tree_missing=1

  local listeners
  listeners="$(gaia_server_listeners "$@")" || return 0
  [ -n "$listeners" ] || return 0

  local pid_list="" listener_port listener_pid
  while IFS="$_gaia_server_tab" read -r listener_port listener_pid; do
    [ -n "$listener_pid" ] && pid_list="$pid_list $listener_pid"
  done <<EOF
$listeners
EOF
  local cwd_report
  # shellcheck disable=SC2086
  cwd_report="$(gaia_server_process_cwds $pid_list)"

  local cwd_pid cwd_path cwd_state identity nested directory
  while IFS="$_gaia_server_tab" read -r listener_port listener_pid; do
    _gaia_server_is_integer "$listener_pid" || continue
    [ "$listener_pid" -gt 1 ] || continue
    cwd_path=""
    cwd_state="unknown"
    while IFS="$_gaia_server_tab" read -r cwd_pid cwd_path cwd_state; do
      [ "$cwd_pid" = "$listener_pid" ] && break
      cwd_path=""
      cwd_state="unknown"
    done <<EOF
$cwd_report
EOF
    [ "$cwd_state" = "live" ] || [ "$cwd_state" = "deleted" ] || continue
    _gaia_server_path_is_under "$cwd_path" "$tree_root" || continue
    [ "$tree_missing" -eq 1 ] || [ "$cwd_state" = "deleted" ] || continue
    # A live checkout between the tree root and the cwd owns that cwd; the
    # attribution is ambiguous, so refuse.
    nested=0
    directory="$cwd_path"
    while [ "$directory" != "$tree_root" ] && [ "${#directory}" -gt "${#tree_root}" ]; do
      if [ -e "$directory/.git" ]; then
        nested=1
        break
      fi
      directory="${directory%/*}"
    done
    [ "$nested" -eq 0 ] || continue
    identity="$(gaia_server_process_identity "$listener_pid")" || continue
    printf '%s\t%s\t%s\n' "$listener_port" "$listener_pid" "$identity"
  done <<EOF
$listeners
EOF
  return 0
}

# gaia_server_stop_removed_tree_listeners <tree-root> <port>...: stops each
# qualifying listener through the verified stop and prints one removed-tree
# report per stop. Unreadable or ambiguous cwd never stops.
gaia_server_stop_removed_tree_listeners() {
  local tree_root candidates
  tree_root="$(_gaia_server_strip_trailing_slash "$1")"
  shift
  candidates="$(_gaia_server_removed_tree_candidates "$tree_root" "$@")"
  [ -n "$candidates" ] || return 0
  local candidate_port candidate_pid candidate_start candidate_command stop_status
  while IFS="$_gaia_server_tab" read -r candidate_port candidate_pid candidate_start candidate_command; do
    [ -n "$candidate_pid" ] || continue
    gaia_server_stop_verified "$candidate_pid" "$candidate_start" "$candidate_command" "$tree_root" "$candidate_port"
    stop_status=$?
    if [ "$stop_status" -eq 0 ]; then
      printf 'GAIA stopped a server on port %s (PID %s) left running from removed worktree %s.\n' "$candidate_port" "$candidate_pid" "$tree_root"
    fi
  done <<EOF
$candidates
EOF
  return 0
}

# gaia_server_reap_dead_sessions <state-directory>: stops the servers of
# launch records whose session host has died, after verifying identity; drops
# records whose process is gone or no longer matches; then drops session files
# whose host is dead and which no launch record names, together with that
# session's kept-worktree occupancy record (worktree-occupancy/<id>.tsv, beside
# the state directory): the reminder judges a tree's holder from the session
# file, so an occupancy record outliving it would hold its tree forever.
gaia_server_reap_dead_sessions() {
  local state_directory="$1" record_file identity stop_status
  [ -n "$state_directory" ] && [ -d "$state_directory" ] || return 0
  # Without a backend a matching process could never be verified, so keep
  # every record for a later pass that can.
  if [ "$(_gaia_server_backend listeners)" = "none" ] || [ "$(_gaia_server_backend cwds)" = "none" ]; then
    return 0
  fi
  for record_file in "$state_directory"/launches/*.tsv; do
    [ -f "$record_file" ] || continue
    if ! _gaia_server_read_launch_record "$record_file"; then
      _gaia_server_diagnostic "dropping malformed launch record ${record_file##*/}"
      rm -f "$record_file"
      continue
    fi
    gaia_server_host_alive "$_gaia_server_record_host_pid" "$_gaia_server_record_host_start" && continue
    identity="$(gaia_server_process_identity "$_gaia_server_record_pid")" || {
      rm -f "$record_file"
      continue
    }
    if [ "$identity" != "$_gaia_server_record_start$_gaia_server_tab$_gaia_server_record_command" ]; then
      rm -f "$record_file"
      continue
    fi
    gaia_server_stop_verified "$_gaia_server_record_pid" "$_gaia_server_record_start" "$_gaia_server_record_command" \
      "$_gaia_server_record_cwd" "$_gaia_server_record_port"
    stop_status=$?
    if [ "$stop_status" -eq 0 ]; then
      printf 'GAIA stopped a %s server on port %s (PID %s) launched by an ended Claude session in %s.\n' \
        "$_gaia_server_record_kind" "$_gaia_server_record_port" "$_gaia_server_record_pid" "$_gaia_server_record_tree"
    fi
    rm -f "$record_file"
  done

  local session_file session_id session_host named
  for session_file in "$state_directory"/sessions/*.tsv; do
    [ -f "$session_file" ] || continue
    if session_host="$(_gaia_server_read_session_host "$session_file")" &&
      gaia_server_host_alive "${session_host%%"$_gaia_server_tab"*}" "${session_host#*"$_gaia_server_tab"}"; then
      continue
    fi
    session_id="${session_file##*/}"
    session_id="${session_id%.tsv}"
    named=0
    for record_file in "$state_directory"/launches/*.tsv; do
      [ -f "$record_file" ] || continue
      _gaia_server_read_launch_record "$record_file" || continue
      if [ "$_gaia_server_record_session" = "$session_id" ]; then
        named=1
        break
      fi
    done
    if [ "$named" -eq 0 ]; then
      rm -f "$session_file"
      rm -f "${state_directory%/*}/worktree-occupancy/$session_id.tsv"
    fi
  done
  return 0
}

_gaia_server_base_port() {
  local value="$1" default="$2"
  if _gaia_server_is_port "$value"; then
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
}

# gaia_server_reap_tombstones <state-directory>: per tombstone, stops the
# removed tree's qualifying listeners on its slot's dev and Storybook ports,
# drops that tree's launch records whose process is gone or no longer
# matches, deletes the tombstone once nothing qualifies, and only then
# applies the age expiry to the tombstones still standing.
gaia_server_reap_tombstones() {
  local state_directory="$1"
  [ -n "$state_directory" ] && [ -d "$state_directory" ] || return 0
  local dev_base storybook_base backend_available=1
  dev_base="$(_gaia_server_base_port "${GAIA_PORTS_DEV_BASE_PORT:-}" 5173)"
  storybook_base="$(_gaia_server_base_port "${GAIA_PORTS_STORYBOOK_BASE_PORT:-}" 6006)"
  if [ "$(_gaia_server_backend listeners)" = "none" ] || [ "$(_gaia_server_backend cwds)" = "none" ]; then
    backend_available=0
  fi

  local tombstone_file line slot tree_root reclaimed_epoch dev_port storybook_port
  local record_file identity now remaining
  for tombstone_file in "$state_directory"/tombstones/*.tsv; do
    [ -f "$tombstone_file" ] || continue
    line=""
    IFS= read -r line <"$tombstone_file" || true
    IFS="$_gaia_server_tab" read -r slot tree_root reclaimed_epoch <<EOF
$line
EOF
    tree_root="$(_gaia_server_strip_trailing_slash "$tree_root")"
    if ! _gaia_server_is_integer "$slot" || ! _gaia_server_is_integer "$reclaimed_epoch" || [ "${tree_root#/}" = "$tree_root" ] || [ "$tree_root" = "/" ]; then
      _gaia_server_diagnostic "dropping malformed tombstone ${tombstone_file##*/}"
      rm -f "$tombstone_file"
      continue
    fi
    dev_port=$((dev_base + slot))
    storybook_port=$((storybook_base + slot))

    if [ "$backend_available" -eq 1 ]; then
      gaia_server_stop_removed_tree_listeners "$tree_root" "$dev_port" "$storybook_port"

      for record_file in "$state_directory"/launches/*.tsv; do
        [ -f "$record_file" ] || continue
        _gaia_server_read_launch_record "$record_file" || continue
        [ "$_gaia_server_record_tree" = "$tree_root" ] || continue
        identity="$(gaia_server_process_identity "$_gaia_server_record_pid")" || {
          rm -f "$record_file"
          continue
        }
        [ "$identity" = "$_gaia_server_record_start$_gaia_server_tab$_gaia_server_record_command" ] || rm -f "$record_file"
      done

      remaining="$(_gaia_server_removed_tree_candidates "$tree_root" "$dev_port" "$storybook_port")"
      if [ -z "$remaining" ]; then
        rm -f "$tombstone_file"
        continue
      fi
    fi

    now="$(date +%s)"
    if [ $((now - reclaimed_epoch)) -gt "$_gaia_server_tombstone_expiry_seconds" ]; then
      rm -f "$tombstone_file"
    fi
  done
  return 0
}
