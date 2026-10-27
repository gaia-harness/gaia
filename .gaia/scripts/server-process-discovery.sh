#!/usr/bin/env bash
# shellcheck shell=bash
#
# GAIA dev-server process library, discovery half: listeners, process
# identity, working directories, and owning-tree attribution.
# Sourced only by server-process-lib.sh, whose header holds the contract,
# the state layout and the test seams. Defines functions; does no work at
# source time.

# shellcheck disable=SC2154  # constants come from server-process-lib.sh

# gaia_server_listeners <port>...: `<port>\t<pid>` per TCP listener on any
# listed port, IPv4 and IPv6, from one probe. rc 3 when no backend exists.
gaia_server_listeners() {
  local port wanted_ports="" lsof_port_list=""
  for port in "$@"; do
    if ! _gaia_server_is_port "$port"; then
      _gaia_server_diagnostic "ignoring invalid port '$port'"
      continue
    fi
    _gaia_server_port_listed "$port" "$wanted_ports" && continue
    wanted_ports="$wanted_ports $port"
    lsof_port_list="${lsof_port_list:+$lsof_port_list,}$port"
  done
  local backend
  backend="$(_gaia_server_backend listeners)"
  [ "$backend" = "none" ] && return 3
  [ -n "$wanted_ports" ] || return 0

  local raw_output
  if [ "$backend" = "lsof" ]; then
    # lsof exits 1 when nothing matches, so its status cannot tell "no
    # listener" from a failure; the parsed output is the answer.
    raw_output="$(lsof -nP "-iTCP:$lsof_port_list" -sTCP:LISTEN -Fpn 2>/dev/null)" || true
  else
    raw_output="$(ss -ltnpH 2>/dev/null)" || {
      _gaia_server_diagnostic "ss -ltnpH failed; listeners unknown"
      return 3
    }
  fi

  local seen=" " line current_pid="" address listener_port pid_list pid remainder
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$backend" = "lsof" ]; then
      case "$line" in
        p*) current_pid="${line#p}" ;;
        n*)
          address="${line#n}"
          listener_port="${address##*:}"
          _gaia_server_is_integer "$current_pid" || continue
          _gaia_server_port_listed "$listener_port" "$wanted_ports" || continue
          case "$seen" in *" $listener_port:$current_pid "*) continue ;; esac
          seen="$seen$listener_port:$current_pid "
          printf '%s\t%s\n' "$listener_port" "$current_pid"
          ;;
      esac
    else
      # ss -H fields: state, receive queue, send queue, local address, peer
      # address, process. The port follows the local address's last colon.
      read -r _ _ _ address _ <<<"$line"
      listener_port="${address##*:}"
      _gaia_server_port_listed "$listener_port" "$wanted_ports" || continue
      pid_list=""
      remainder="$line"
      while :; do
        case "$remainder" in
          *pid=*) ;;
          *) break ;;
        esac
        remainder="${remainder#*pid=}"
        pid="${remainder%%[!0-9]*}"
        _gaia_server_is_integer "$pid" && pid_list="$pid_list $pid"
      done
      [ -n "$pid_list" ] || pid_list=" 0"
      for pid in $pid_list; do
        case "$seen" in *" $listener_port:$pid "*) continue ;; esac
        seen="$seen$listener_port:$pid "
        printf '%s\t%s\n' "$listener_port" "$pid"
      done
    fi
  done <<EOF
$raw_output
EOF
  return 0
}

# rc 0 when the process exists and is not a zombie (a zombie has exited; only
# its parent has not reaped it yet).
_gaia_server_pid_alive() {
  _gaia_server_is_integer "$1" || return 1
  local process_state
  process_state="$(LC_ALL=C ps -o stat= -p "$1" 2>/dev/null)" || return 1
  process_state="${process_state#"${process_state%%[! ]*}"}"
  [ -n "$process_state" ] || return 1
  case "$process_state" in
    Z*) return 1 ;;
  esac
  return 0
}

# gaia_server_process_identity <pid>: `<start>\t<command>`, the start time
# with whitespace runs collapsed and the command with tabs and newlines turned
# to spaces. rc 1 when the process is gone or unreadable.
gaia_server_process_identity() {
  local pid="$1"
  _gaia_server_is_integer "$pid" || return 1
  [ "$pid" -ge 1 ] || return 1
  _gaia_server_pid_alive "$pid" || return 1
  local start command
  start="$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
  # Unquoted on purpose: word splitting is what collapses whitespace runs.
  # shellcheck disable=SC2086
  start="$(printf '%s ' $start)"
  start="${start% }"
  [ -n "$start" ] || return 1
  command="$(LC_ALL=C ps -o command= -p "$pid" 2>/dev/null)" || return 1
  command="$(printf '%s' "$command" | tr '\t\n' '  ')"
  command="${command%"${command##*[! ]}"}"
  [ -n "$command" ] || return 1
  printf '%s\t%s\n' "$start" "$command"
}

# Classifies one reported working directory. Args: the reported path, the
# inode the backend reported for it (empty when it reported none). Prints
# `<cwd>\t<state>`.
_gaia_server_classify_cwd() {
  local reported_path="$1" reported_inode="$2" current_inode
  case "$reported_path" in
    *' (deleted)')
      printf '%s\tdeleted\n' "${reported_path% (deleted)}"
      return 0
      ;;
    /*) ;;
    *)
      printf 'unknown\tunknown\n'
      return 0
      ;;
  esac
  if [ ! -e "$reported_path" ]; then
    printf '%s\tdeleted\n' "$reported_path"
    return 0
  fi
  if ! _gaia_server_is_integer "$reported_inode"; then
    printf 'unknown\tunknown\n'
    return 0
  fi
  if ! current_inode="$(_gaia_server_inode "$reported_path")"; then
    printf 'unknown\tunknown\n'
    return 0
  fi
  if [ "$current_inode" = "$reported_inode" ]; then
    printf '%s\tlive\n' "$reported_path"
  else
    printf '%s\tdeleted\n' "$reported_path"
  fi
}

# gaia_server_process_cwds <pid>...: `<pid>\t<cwd>\t<state>` per pid, from one
# batched lookup. state is live, deleted, or unknown; an unknown entry prints
# `unknown` in the cwd field too.
gaia_server_process_cwds() {
  local pid valid_pids="" lsof_pid_list=""
  for pid in "$@"; do
    if _gaia_server_is_integer "$pid" && [ "$pid" -ge 1 ]; then
      valid_pids="$valid_pids $pid"
      lsof_pid_list="${lsof_pid_list:+$lsof_pid_list,}$pid"
    else
      printf '%s\tunknown\tunknown\n' "$pid"
    fi
  done
  [ -n "$valid_pids" ] || return 0

  local backend
  backend="$(_gaia_server_backend cwds)"
  if [ "$backend" = "none" ]; then
    for pid in $valid_pids; do
      printf '%s\tunknown\tunknown\n' "$pid"
    done
    return 0
  fi

  local reported_pids="" reported_paths="" reported_inodes=""
  local reported_path reported_inode
  if [ "$backend" = "lsof" ]; then
    local raw_output line current_pid="" current_path="" current_inode=""
    raw_output="$(lsof -a -d cwd -p "$lsof_pid_list" -Fpin 2>/dev/null)" || true
    # Records are collected into three parallel newline-separated lists, then
    # matched per requested pid below; bash 3.2 has no associative arrays.
    while IFS= read -r line; do
      case "$line" in
        p*)
          if _gaia_server_is_integer "$current_pid"; then
            reported_pids="$reported_pids$current_pid$_gaia_server_tab"
            reported_paths="$reported_paths$current_path$_gaia_server_tab"
            reported_inodes="$reported_inodes$current_inode$_gaia_server_tab"
          fi
          current_pid="${line#p}"
          current_path=""
          current_inode=""
          ;;
        i*) current_inode="${line#i}" ;;
        n*) current_path="${line#n}" ;;
      esac
    done <<EOF
$raw_output
EOF
    if _gaia_server_is_integer "$current_pid"; then
      reported_pids="$reported_pids$current_pid$_gaia_server_tab"
      reported_paths="$reported_paths$current_path$_gaia_server_tab"
      reported_inodes="$reported_inodes$current_inode$_gaia_server_tab"
    fi
    for pid in $valid_pids; do
      local remaining_pids="$reported_pids" remaining_paths="$reported_paths" remaining_inodes="$reported_inodes"
      local candidate_pid found=0
      reported_path=""
      reported_inode=""
      while [ -n "$remaining_pids" ]; do
        candidate_pid="${remaining_pids%%"$_gaia_server_tab"*}"
        remaining_pids="${remaining_pids#*"$_gaia_server_tab"}"
        reported_path="${remaining_paths%%"$_gaia_server_tab"*}"
        remaining_paths="${remaining_paths#*"$_gaia_server_tab"}"
        reported_inode="${remaining_inodes%%"$_gaia_server_tab"*}"
        remaining_inodes="${remaining_inodes#*"$_gaia_server_tab"}"
        if [ "$candidate_pid" = "$pid" ]; then
          found=1
          break
        fi
      done
      if [ "$found" -eq 1 ] && [ -n "$reported_path" ]; then
        printf '%s\t%s\n' "$pid" "$(_gaia_server_classify_cwd "$reported_path" "$reported_inode")"
      else
        printf '%s\tunknown\tunknown\n' "$pid"
      fi
    done
  else
    for pid in $valid_pids; do
      reported_path="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || reported_path=""
      if [ -z "$reported_path" ]; then
        printf '%s\tunknown\tunknown\n' "$pid"
        continue
      fi
      reported_inode="$(stat -L -c %i "/proc/$pid/cwd" 2>/dev/null)" || reported_inode=""
      printf '%s\t%s\n' "$pid" "$(_gaia_server_classify_cwd "$reported_path" "$reported_inode")"
    done
  fi
  return 0
}

# gaia_server_owning_tree <cwd>: the nearest enclosing directory holding a
# `.git` file or directory, physically resolved. A linked worktree nested
# inside the main checkout owns its own servers. rc 1 when the cwd does not
# exist or no ancestor holds `.git`.
gaia_server_owning_tree() {
  local directory
  [ -d "$1" ] || return 1
  directory="$(cd -P "$1" 2>/dev/null && pwd -P)" || return 1
  [ -n "$directory" ] || return 1
  while :; do
    if [ -e "$directory/.git" ]; then
      printf '%s\n' "$directory"
      return 0
    fi
    [ "$directory" = "/" ] && return 1
    directory="${directory%/*}"
    [ -n "$directory" ] || directory="/"
  done
}

# gaia_server_listener_owner <port> <tree-root>: exactly one of `free`,
# `own <pid>`, `foreign <pid> <cwd>`, `foreign <pid> unknown`, `unknown`.
# With several listeners on the port, any non-own listener is the answer.
# Always rc 0.
gaia_server_listener_owner() {
  local port="$1" tree_root listeners listeners_status
  tree_root="$(_gaia_server_physical_or_literal "$2")"
  listeners="$(gaia_server_listeners "$port")"
  listeners_status=$?
  if [ "$listeners_status" -ne 0 ]; then
    printf 'unknown\n'
    return 0
  fi
  if [ -z "$listeners" ]; then
    printf 'free\n'
    return 0
  fi

  local pid_list="" listener_port listener_pid
  while IFS="$_gaia_server_tab" read -r listener_port listener_pid; do
    [ -n "$listener_pid" ] && pid_list="$pid_list $listener_pid"
  done <<EOF
$listeners
EOF
  local cwd_report
  # shellcheck disable=SC2086
  cwd_report="$(gaia_server_process_cwds $pid_list)"

  local first_own="" first_foreign="" cwd_pid cwd_path cwd_state owning_tree
  while IFS="$_gaia_server_tab" read -r cwd_pid cwd_path cwd_state; do
    [ -n "$cwd_pid" ] || continue
    if [ "$cwd_state" = "live" ] && owning_tree="$(gaia_server_owning_tree "$cwd_path")" && [ "$owning_tree" = "$tree_root" ]; then
      [ -n "$first_own" ] || first_own="own $cwd_pid"
      continue
    fi
    if [ -z "$first_foreign" ]; then
      if [ "$cwd_state" = "unknown" ]; then
        first_foreign="foreign $cwd_pid unknown"
      else
        first_foreign="foreign $cwd_pid $cwd_path"
      fi
    fi
  done <<EOF
$cwd_report
EOF
  if [ -n "$first_foreign" ]; then
    printf '%s\n' "$first_foreign"
  elif [ -n "$first_own" ]; then
    printf '%s\n' "$first_own"
  else
    printf 'foreign 0 unknown\n'
  fi
  return 0
}
