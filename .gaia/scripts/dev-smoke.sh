#!/usr/bin/env bash
# shellcheck shell=bash
#
# The Quality Gate's dev smoke test: starts this tree's dev server on this
# tree's dev port, requests one route until it answers, follows same-origin
# redirects, and stops the server it started.
#
#   bash .gaia/scripts/dev-smoke.sh [--tree <directory>] [--path <route>] [--timeout <seconds>]
#
# The port comes from ports.sh. A port something already holds is refused with
# the ask-first message, never freed: the holder may be another session's or a
# human's server, and a smoke test that answered from it would prove nothing
# about this tree anyway. The one exception is a dev server whose launch record
# names this Claude process (this session's id, or its host, which /clear and
# /resume keep), this tree and this port: that one is stopped first. Every stop goes through gaia_server_stop_verified, to
# that recorded server or to a listener descended from the process this
# script launched, so no pattern kill and no port-wide kill ever runs. An exit
# or interrupt at any point still stops what was started.
#
# Exit codes: 0 the route answered HTTP 200, directly or after at most five
# redirects within the dev server's own origin, and the server stopped; 1 the
# smoke test failed (another final status, a redirect off that origin or past
# the limit, the server exited or never answered in time, or the server it
# started could not be stopped); 2 usage; 3 refused to start (no
# package with a react-router.config.* file, no resolvable port, the port is
# already held, or no process backend to tell who holds it).
#
# Test seam (not adopter tuning): GAIA_DEV_SMOKE_SERVER_COMMAND replaces
# `pnpm dev` with a bash command string, run from the port package directory
# with GAIA_DEV_SMOKE_PORT exported.

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=worktree-ports-lib.sh
. "$script_directory/worktree-ports-lib.sh"
# shellcheck source=server-process-lib.sh
. "$script_directory/server-process-lib.sh"

ask_first_sentence='Never stop a process on a port another live tree owns without asking the user first.'
ports_hint="Run bash .gaia/scripts/ports.sh to see this tree's ports."
tab=$'\t'
poll_interval_seconds=0.2
# pnpm forwards SIGTERM to its child and exits once the child does; five
# seconds covers a dev server flushing its watchers.
reap_wait_tenths=50

usage() {
  printf 'usage: dev-smoke.sh [--tree <directory>] [--path <route>] [--timeout <seconds>]\n' >&2
  exit 2
}

tree_argument="$PWD"
route_path='/'
timeout_seconds=120
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tree | --path | --timeout) [ "$#" -ge 2 ] || usage ;;
    *) usage ;;
  esac
  case "$1" in
    --tree) tree_argument="$2" ;;
    --path) route_path="$2" ;;
    --timeout) timeout_seconds="$2" ;;
  esac
  shift 2
done
case "$route_path" in
  /*) ;;
  *) usage ;;
esac
case "$timeout_seconds" in
  '' | *[!0-9]*) usage ;;
esac
[ "$timeout_seconds" -ge 1 ] || usage

tree_root="$(gaia_resolve_tree_root "$tree_argument" 2>/dev/null)" || {
  printf 'GAIA dev smoke: %s is not inside a git checkout.\n' "$tree_argument" >&2
  exit 2
}
package_directory="$(gaia_ports_package_directory "$tree_root")" || {
  printf 'GAIA dev smoke: no package under %s has a react-router.config.* file, so there is no dev server to smoke test.\n' "$tree_root" >&2
  exit 3
}
# ports.sh prints its own reason on stderr when it cannot answer.
dev_port="$(bash "$script_directory/ports.sh" --tree "$tree_root" --field dev)" || exit 3

holder="$(gaia_server_listener_owner "$dev_port" "$tree_root")"
case "$holder" in
  own*)
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] &&
      gaia_server_stop_session_launches "$(_gaia_server_state_directory "$tree_root")" \
        "$CLAUDE_CODE_SESSION_ID" "$tree_root" "$dev_port"; then
      holder="$(gaia_server_listener_owner "$dev_port" "$tree_root")"
    fi
    ;;
esac
case "$holder" in
  free) ;;
  unknown)
    printf 'GAIA dev smoke: cannot tell whether port %s is free (no lsof, and no ss with /proc), so a server answering there could not be told from this one, and this one could not be stopped safely. Refusing to start.\n' "$dev_port" >&2
    exit 3
    ;;
  *)
    read -r _ holder_pid holder_path <<EOF
$holder
EOF
    case "$holder" in
      own*) holder_path="$tree_root" ;;
    esac
    holder_detail=''
    [ "$holder_pid" -gt 0 ] 2>/dev/null && holder_detail=" by PID $holder_pid"
    [ -n "$holder_path" ] && [ "$holder_path" != unknown ] && holder_detail="$holder_detail in $holder_path"
    printf "GAIA dev smoke: port %s, this tree's dev server port, is already in use%s. Refusing to start the smoke test. %s %s\n" \
      "$dev_port" "$holder_detail" "$ask_first_sentence" "$ports_hint" >&2
    exit 3
    ;;
esac

server_log="$(mktemp "${TMPDIR:-/tmp}/gaia-dev-smoke.XXXXXX")" || {
  printf 'GAIA dev smoke: could not create a log file.\n' >&2
  exit 1
}
started_pid=''

# rc 0 when pid descends from (or is) the launched process.
descends_from_started() {
  local walk_pid="$1" step=0 parent_pid
  while [ "$step" -lt 64 ]; do
    [ "$walk_pid" = "$started_pid" ] && return 0
    parent_pid="$(ps -o ppid= -p "$walk_pid" 2>/dev/null)" || return 1
    parent_pid="${parent_pid//[!0-9]/}"
    [ -n "$parent_pid" ] && [ "$parent_pid" -gt 1 ] || return 1
    walk_pid="$parent_pid"
    step=$((step + 1))
  done
  return 1
}

# Stops the started server's listener through the verified stop, then reaps the
# launched process itself, which this script owns as its own child. rc 1 when
# something it started is still running.
stop_started_server() {
  [ -n "$started_pid" ] || return 0
  local listeners listener_port listener_pid identity listener_start listener_command stop_failed=0
  listeners="$(gaia_server_listeners "$dev_port")" || listeners=''
  while IFS="$tab" read -r listener_port listener_pid; do
    [ -n "$listener_pid" ] || continue
    descends_from_started "$listener_pid" || continue
    identity="$(gaia_server_process_identity "$listener_pid")" || continue
    listener_start="${identity%%"$tab"*}"
    listener_command="${identity#*"$tab"}"
    gaia_server_stop_verified "$listener_pid" "$listener_start" "$listener_command" "$tree_root" "$listener_port"
    [ "$?" -eq 1 ] && stop_failed=1
  done <<EOF
$listeners
EOF
  if gaia_server_pid_alive "$started_pid"; then
    kill -TERM "$started_pid" 2>/dev/null
    gaia_server_wait_for_exit "$started_pid" "$reap_wait_tenths" || {
      kill -KILL "$started_pid" 2>/dev/null
      gaia_server_wait_for_exit "$started_pid" 10 || stop_failed=1
    }
  fi
  wait "$started_pid" 2>/dev/null
  started_pid=''
  if [ "$stop_failed" -eq 1 ]; then
    printf 'GAIA dev smoke: the dev server it started on port %s is still running and was not stopped. %s\n' "$dev_port" "$ports_hint" >&2
    return 1
  fi
  return 0
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
  stop_started_server
  rm -f "$server_log"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print_server_log() {
  printf 'GAIA dev smoke: last lines of the dev server output:\n' >&2
  tail -n 30 "$server_log" >&2
}

server_command="${GAIA_DEV_SMOKE_SERVER_COMMAND:-pnpm dev}"
(cd "$package_directory" && GAIA_DEV_SMOKE_PORT="$dev_port" exec bash -c "$server_command") >"$server_log" 2>&1 </dev/null &
started_pid="$!"

fail_smoke() {
  printf 'GAIA dev smoke: %s\n' "$1" >&2
  print_server_log
  exit 1
}

# Sets status (000 when nothing answered) and redirect_target, the absolute
# Location curl resolved, empty when there is none. curl is not given -L: it
# would follow a redirect to any host.
request_once() {
  local response
  response="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "$1" 2>/dev/null)" || response='000'
  status="${response%% *}"
  redirect_target="${response#"$status"}"
  redirect_target="${redirect_target# }"
}

origin="http://localhost:$dev_port"
url="$origin$route_path"
# An app routing `/` through a login page and on to a landing page takes two
# hops; five leaves room for a locale or trailing-slash hop and still ends a loop.
maximum_redirects=5
deadline=$((SECONDS + timeout_seconds))
while :; do
  gaia_server_pid_alive "$started_pid" || fail_smoke "the dev server exited before $url answered."
  request_once "$url"
  [ "$status" = '000' ] || break
  [ "$SECONDS" -lt "$deadline" ] || fail_smoke "$url did not answer within $timeout_seconds seconds."
  sleep "$poll_interval_seconds"
done

# A redirect is followed only within this dev server's origin: a page elsewhere
# answering 200 proves nothing about this tree.
final_url="$url"
redirect_count=0
while :; do
  case "$status" in
    3??) ;;
    *) break ;;
  esac
  [ -n "$redirect_target" ] || fail_smoke "$final_url answered HTTP $status with no redirect target, expected 200."
  case "$redirect_target" in
    "$origin" | "$origin"/*) ;;
    *) fail_smoke "$final_url redirected to $redirect_target, outside $origin, expected 200 from this dev server." ;;
  esac
  [ "$redirect_count" -lt "$maximum_redirects" ] || fail_smoke "$url redirected more than $maximum_redirects times, expected 200."
  redirect_count=$((redirect_count + 1))
  final_url="$redirect_target"
  request_once "$final_url"
  [ "$status" != '000' ] || fail_smoke "$final_url, a redirect from $url, did not answer."
done

redirect_note=''
[ "$final_url" = "$url" ] || redirect_note=" at $final_url"
[ "$status" = 200 ] || fail_smoke "$url answered HTTP $status$redirect_note, expected 200."

[ -z "$redirect_note" ] || redirect_note=" after following redirects to $final_url"
stop_started_server || exit 1
printf 'GAIA dev smoke: %s answered HTTP 200%s; the dev server it started is stopped.\n' "$url" "$redirect_note"
exit 0
