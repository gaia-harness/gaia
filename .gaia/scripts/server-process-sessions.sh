#!/usr/bin/env bash
# shellcheck shell=bash
#
# GAIA dev-server process library, record half: the session-host and launch
# records that let a later session stop servers an ended Claude session left
# running.
# Sourced only by server-process-lib.sh, whose header holds the contract,
# the state layout and the test seams. Defines functions; does no work at
# source time.

# shellcheck disable=SC2154  # constants come from server-process-lib.sh

# The session host: the first ancestor of the caller's parent that is not a
# plain shell or `env`.
_gaia_server_discover_host_pid() {
  local walk_pid="$PPID" step=0 line parent_pid command_name
  while [ "$step" -lt "$_gaia_server_ancestry_step_limit" ]; do
    _gaia_server_is_integer "$walk_pid" || return 1
    [ "$walk_pid" -gt 1 ] || return 1
    line="$(LC_ALL=C ps -o ppid=,comm= -p "$walk_pid" 2>/dev/null)" || return 1
    line="${line#"${line%%[! ]*}"}"
    parent_pid="${line%% *}"
    command_name="${line#* }"
    command_name="${command_name#"${command_name%%[! ]*}"}"
    command_name="${command_name##*/}"
    command_name="${command_name#-}"
    case "$command_name" in
      sh | bash | zsh | dash | env) ;;
      *)
        printf '%s' "$walk_pid"
        return 0
        ;;
    esac
    walk_pid="$parent_pid"
    step=$((step + 1))
  done
  return 1
}

# Writes content to a file through a temporary file in the same directory.
_gaia_server_write_atomic() {
  local target="$1" content="$2" temporary
  temporary="$target.tmp.$$"
  printf '%s\n' "$content" >"$temporary" 2>/dev/null || {
    rm -f "$temporary"
    return 1
  }
  mv -f "$temporary" "$target" 2>/dev/null || {
    rm -f "$temporary"
    return 1
  }
}

# gaia_server_session_register <state-directory> <session-id> [<host-pid>]:
# records the session's host process. The third argument, then
# GAIA_PORTS_HOST_PID, override discovery. Writes only when the host changed.
gaia_server_session_register() {
  local state_directory="$1" session_id="$2" host_pid="${3:-${GAIA_PORTS_HOST_PID:-}}"
  if [ -z "$state_directory" ]; then
    _gaia_server_diagnostic "session register: no state directory"
    return 1
  fi
  if ! _gaia_server_is_session_id "$session_id"; then
    _gaia_server_diagnostic "session register: invalid session id"
    return 1
  fi
  if [ -z "$host_pid" ]; then
    host_pid="$(_gaia_server_discover_host_pid)" || host_pid=""
  fi
  if ! _gaia_server_is_integer "$host_pid" || [ "$host_pid" -le 1 ]; then
    _gaia_server_diagnostic "session register: no session host found"
    return 1
  fi
  local identity
  identity="$(gaia_server_process_identity "$host_pid")" || {
    _gaia_server_diagnostic "session register: host pid $host_pid is not readable"
    return 1
  }
  mkdir -p "$state_directory/sessions" 2>/dev/null || return 1
  local session_file="$state_directory/sessions/$session_id.tsv" existing=""
  if [ -f "$session_file" ]; then
    IFS= read -r existing <"$session_file" || true
  fi
  local host_record="$host_pid$_gaia_server_tab$identity"
  case "$existing" in
    "$host_record$_gaia_server_tab"*) return 0 ;;
  esac
  _gaia_server_write_atomic "$session_file" "$host_record$_gaia_server_tab$(date +%s)"
}

# gaia_server_host_alive <host-pid> <host-start>: rc 0 when the host is alive
# and its start time still matches.
gaia_server_host_alive() {
  local identity
  _gaia_server_is_integer "$1" || return 1
  [ "$1" -gt 1 ] || return 1
  kill -0 "$1" 2>/dev/null || _gaia_server_pid_alive "$1" || return 1
  identity="$(gaia_server_process_identity "$1")" || return 1
  [ "${identity%%"$_gaia_server_tab"*}" = "$2" ]
}

# Prints `<host-pid>\t<host-start>` from a session file; rc 1 when malformed.
_gaia_server_read_session_host() {
  local line host_pid host_start
  [ -f "$1" ] || return 1
  IFS= read -r line <"$1" || [ -n "$line" ] || return 1
  host_pid="${line%%"$_gaia_server_tab"*}"
  line="${line#*"$_gaia_server_tab"}"
  host_start="${line%%"$_gaia_server_tab"*}"
  _gaia_server_is_integer "$host_pid" || return 1
  [ -n "$host_start" ] || return 1
  printf '%s\t%s\n' "$host_pid" "$host_start"
}

# gaia_server_record_launch <state-directory> <pid> <port> <kind> <tree-root>:
# records a server launched by a live Claude session, attributed by process
# ancestry, falling back to sessions/$CLAUDE_CODE_SESSION_ID.tsv when the
# chain was broken by reparenting. Never probes a port. rc 0 whether or not a
# record was written; rc 1 on invalid arguments.
gaia_server_record_launch() {
  local state_directory="$1" pid="$2" port="$3" kind="$4" tree_root="$5"
  if [ -z "$state_directory" ] || ! _gaia_server_is_integer "$pid" || [ "$pid" -le 1 ] || ! _gaia_server_is_port "$port"; then
    _gaia_server_diagnostic "record launch: invalid state directory, pid, or port"
    return 1
  fi
  case "$kind" in
    dev | storybook) ;;
    *)
      _gaia_server_diagnostic "record launch: kind must be dev or storybook"
      return 1
      ;;
  esac
  case "$tree_root" in
    /*) ;;
    *)
      _gaia_server_diagnostic "record launch: tree root must be absolute"
      return 1
      ;;
  esac
  tree_root="$(_gaia_server_physical_or_literal "$tree_root")"

  local identity
  identity="$(gaia_server_process_identity "$pid")" || return 0

  local session_id="" host_pid="" host_start="" session_file session_host
  local ancestor_pid parent_pid step=0 candidate_host_pid candidate_host_start
  ancestor_pid="$pid"
  if [ -d "$state_directory/sessions" ]; then
    while [ "$step" -lt "$_gaia_server_ancestry_step_limit" ] && [ -z "$session_id" ]; do
      parent_pid="$(ps -o ppid= -p "$ancestor_pid" 2>/dev/null)" || break
      parent_pid="${parent_pid//[!0-9]/}"
      _gaia_server_is_integer "$parent_pid" || break
      [ "$parent_pid" -gt 1 ] || break
      for session_file in "$state_directory"/sessions/*.tsv; do
        [ -f "$session_file" ] || continue
        session_host="$(_gaia_server_read_session_host "$session_file")" || continue
        candidate_host_pid="${session_host%%"$_gaia_server_tab"*}"
        candidate_host_start="${session_host#*"$_gaia_server_tab"}"
        [ "$candidate_host_pid" = "$parent_pid" ] || continue
        gaia_server_host_alive "$candidate_host_pid" "$candidate_host_start" || continue
        session_id="${session_file##*/}"
        session_id="${session_id%.tsv}"
        _gaia_server_is_session_id "$session_id" || { session_id=""; continue; }
        host_pid="$candidate_host_pid"
        host_start="$candidate_host_start"
        break
      done
      ancestor_pid="$parent_pid"
      step=$((step + 1))
    done
  fi

  if [ -z "$session_id" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    if _gaia_server_is_session_id "$CLAUDE_CODE_SESSION_ID"; then
      session_file="$state_directory/sessions/$CLAUDE_CODE_SESSION_ID.tsv"
      if session_host="$(_gaia_server_read_session_host "$session_file")"; then
        candidate_host_pid="${session_host%%"$_gaia_server_tab"*}"
        candidate_host_start="${session_host#*"$_gaia_server_tab"}"
        if gaia_server_host_alive "$candidate_host_pid" "$candidate_host_start"; then
          session_id="$CLAUDE_CODE_SESSION_ID"
          host_pid="$candidate_host_pid"
          host_start="$candidate_host_start"
        fi
      fi
    else
      _gaia_server_diagnostic "record launch: ignoring invalid CLAUDE_CODE_SESSION_ID"
    fi
  fi
  [ -n "$session_id" ] || return 0

  local cwd_line cwd_path cwd_state
  cwd_line="$(gaia_server_process_cwds "$pid")"
  cwd_path="$(printf '%s' "$cwd_line" | cut -f2)"
  cwd_state="$(printf '%s' "$cwd_line" | cut -f3)"
  if [ "$cwd_state" != "live" ]; then
    _gaia_server_diagnostic "record launch: working directory of pid $pid is not readable; not recorded"
    return 0
  fi

  mkdir -p "$state_directory/launches" 2>/dev/null || return 0
  _gaia_server_write_atomic "$state_directory/launches/$pid.tsv" \
    "$pid$_gaia_server_tab$identity$_gaia_server_tab$cwd_path$_gaia_server_tab$port$_gaia_server_tab$kind$_gaia_server_tab$session_id$_gaia_server_tab$host_pid$_gaia_server_tab$host_start$_gaia_server_tab$tree_root" || true
  return 0
}

# Reads a launch record into the _gaia_server_record_* variables. rc 1 when
# malformed or when the pid field disagrees with the file name.
_gaia_server_read_launch_record() {
  local record_file="$1" line file_pid
  _gaia_server_record_pid=""
  _gaia_server_record_start=""
  _gaia_server_record_command=""
  _gaia_server_record_cwd=""
  _gaia_server_record_port=""
  _gaia_server_record_kind=""
  _gaia_server_record_session=""
  _gaia_server_record_host_pid=""
  _gaia_server_record_host_start=""
  _gaia_server_record_tree=""
  [ -f "$record_file" ] || return 1
  IFS= read -r line <"$record_file" || [ -n "$line" ] || return 1
  IFS="$_gaia_server_tab" read -r _gaia_server_record_pid _gaia_server_record_start _gaia_server_record_command \
    _gaia_server_record_cwd _gaia_server_record_port _gaia_server_record_kind _gaia_server_record_session \
    _gaia_server_record_host_pid _gaia_server_record_host_start _gaia_server_record_tree <<EOF
$line
EOF
  file_pid="${record_file##*/}"
  file_pid="${file_pid%.tsv}"
  _gaia_server_is_integer "$_gaia_server_record_pid" || return 1
  [ "$file_pid" = "$_gaia_server_record_pid" ] || return 1
  _gaia_server_is_port "$_gaia_server_record_port" || return 1
  _gaia_server_is_integer "$_gaia_server_record_host_pid" || return 1
  [ -n "$_gaia_server_record_tree" ] || return 1
  return 0
}

# gaia_server_cleanup_needed <state-directory>: rc 0 when a reap has work: a
# slots.tsv entry whose directory is missing, any tombstone, or a launch
# record whose host is not alive. Reads files and `ps` only; never lsof or ss.
gaia_server_cleanup_needed() {
  local state_directory="$1" tree_root record_file
  [ -n "$state_directory" ] && [ -d "$state_directory" ] || return 1
  if [ -f "$state_directory/slots.tsv" ]; then
    while IFS="$_gaia_server_tab" read -r _ tree_root _; do
      [ -n "$tree_root" ] || continue
      [ -d "$tree_root" ] || return 0
    done <"$state_directory/slots.tsv"
  fi
  for record_file in "$state_directory"/tombstones/*.tsv; do
    [ -e "$record_file" ] && return 0
  done
  for record_file in "$state_directory"/launches/*.tsv; do
    [ -f "$record_file" ] || continue
    # A malformed record is work too: the reap deletes it.
    _gaia_server_read_launch_record "$record_file" || return 0
    gaia_server_host_alive "$_gaia_server_record_host_pid" "$_gaia_server_record_host_start" || return 0
  done
  return 1
}
