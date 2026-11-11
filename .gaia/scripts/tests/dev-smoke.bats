#!/usr/bin/env bats
#
# Suite for .gaia/scripts/dev-smoke.sh: the Quality Gate's dev smoke test.
# Proves it answers on this tree's dev port, stops only the server it started
# (also when the listener is a grandchild, the way pnpm runs vite), follows
# only same-origin redirects to a final 200, and refuses a port someone else
# holds without touching the holder.
#
# Fixtures: a throwaway git repository with a port package, an ephemeral
# slot-0 dev port through GAIA_PORTS_DEV_BASE_PORT, a stand-in dev server
# through the GAIA_DEV_SMOKE_SERVER_COMMAND seam, and real listeners from the
# ports fixtures. Every process a test starts itself is killed in teardown.
#
# Run: bash .gaia/scripts/bats5.sh .gaia/scripts/tests/dev-smoke.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
  # DEV_SMOKE_SCRIPT points the suite at a mutated copy to prove each guard can fail.
  SCRIPT="${DEV_SMOKE_SCRIPT:-$REPO_ROOT/.gaia/scripts/dev-smoke.sh}"
  HTTP_FIXTURE="$REPO_ROOT/.gaia/tests/fixtures/ports/http-status.mjs"
  LISTENER_FIXTURE="$REPO_ROOT/.gaia/tests/fixtures/ports/listen.mjs"
  SCRATCH="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  STARTED_PIDS=()
  unset CLAUDE_CODE_SESSION_ID GAIA_PORTS_STATE_DIRECTORY SITE_URL GAIA_DEV_SMOKE_SERVER_COMMAND
  export GAIA_PORTS_PROCESS_PROBE="${GAIA_PORTS_PROCESS_PROBE:-auto}"
  DEV_PORT=$((20000 + (RANDOM % 7000)))
  export GAIA_PORTS_DEV_BASE_PORT="$DEV_PORT" GAIA_PORTS_STORYBOOK_BASE_PORT=$((DEV_PORT + 300))

  command -v node >/dev/null 2>&1 || skip "node is required for the server fixtures"
  command -v curl >/dev/null 2>&1 || skip "curl is required"
  if ! command -v lsof >/dev/null 2>&1; then
    { [ -e /proc/self ] && command -v ss >/dev/null 2>&1; } || skip "no process backend (lsof, or /proc with ss) on this host"
  fi

  mkdir -p "$SCRATCH/tree/apps/web" "$SCRATCH/elsewhere"
  git init -q -b main "$SCRATCH/tree"
  TREE="$(cd "$SCRATCH/tree" && pwd -P)"
  : >"$TREE/apps/web/react-router.config.ts"
}

teardown() {
  local started_pid
  for started_pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$started_pid" ] && kill -KILL "$started_pid" 2>/dev/null
  done
  return 0
}

process_running() {
  local process_state
  process_state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  process_state="${process_state// /}"
  [ -n "$process_state" ] || return 1
  case "$process_state" in
    Z*) return 1 ;;
  esac
  return 0
}

# rc 0 when something listens on the port.
port_listening() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP "-iTCP:$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
  fi
}

# start_listener <directory> [<port>]: a detached TCP listener on <port>,
# default DEV_PORT, with cwd <directory>. Sets LISTENER_PID.
start_listener() {
  local log="$SCRATCH/listener-$RANDOM.log" attempt=0
  (cd "$1" && nohup node "$LISTENER_FIXTURE" "${2:-$DEV_PORT}" 127.0.0.1 >"$log" 2>&1 </dev/null 3>&- &)
  while [ "$attempt" -lt 100 ]; do
    grep -q '^listening ' "$log" 2>/dev/null && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  LISTENER_PID="$(sed -n 's/^listening \([0-9][0-9]*\)$/\1/p' "$log")"
  [ -n "$LISTENER_PID" ] || return 1
  STARTED_PIDS+=("$LISTENER_PID")
}

# server_command <status> [<location>]: the stand-in dev server, writing its
# pid where a test can read it after the script returns. With <location>, its
# `/` 302s there.
server_command() {
  printf 'echo $$ >%q; exec node %q "$GAIA_DEV_SMOKE_PORT" %q %q' "$SCRATCH/server.pid" "$HTTP_FIXTURE" "$1" "${2:-}"
}

# The stand-in server the script launched is gone and nothing listens on the
# port. The pid joins STARTED_PIDS first so a failed stop is still cleaned up.
assert_server_stopped() {
  local server_pid
  server_pid="$(cat "$SCRATCH/server.pid")"
  STARTED_PIDS+=("$server_pid")
  process_running "$server_pid" && return 1
  port_listening "$DEV_PORT" && return 1
  return 0
}

@test "200: the route answers, exit 0, and the server it started is stopped" {
  GAIA_DEV_SMOKE_SERVER_COMMAND="$(server_command 200)"
  export GAIA_DEV_SMOKE_SERVER_COMMAND
  run bash "$SCRIPT" --tree "$TREE" --timeout 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"localhost:$DEV_PORT/ answered HTTP 200"* ]]
  assert_server_stopped
}

@test "grandchild listener: a wrapper between the script and the server is stopped with it" {
  export GAIA_DEV_SMOKE_SERVER_COMMAND="sh -c 'node \"$HTTP_FIXTURE\" \"\$GAIA_DEV_SMOKE_PORT\" 200 & echo \$! >\"$SCRATCH/server.pid\"; wait'"
  run bash "$SCRIPT" --tree "$TREE" --timeout 30
  [ "$status" -eq 0 ]
  assert_server_stopped
}

@test "non-200: exit 1 names the status, and the server is still stopped" {
  GAIA_DEV_SMOKE_SERVER_COMMAND="$(server_command 500)"
  export GAIA_DEV_SMOKE_SERVER_COMMAND
  run bash "$SCRIPT" --tree "$TREE" --timeout 30
  [ "$status" -eq 1 ]
  [[ "$output" == *"answered HTTP 500, expected 200"* ]]
  assert_server_stopped
}

@test "same-origin redirect to a page that renders: exit 0" {
  GAIA_DEV_SMOKE_SERVER_COMMAND="$(server_command 200 /login)"
  export GAIA_DEV_SMOKE_SERVER_COMMAND
  run bash "$SCRIPT" --tree "$TREE" --timeout 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"localhost:$DEV_PORT/ answered HTTP 200 after following redirects to http://localhost:$DEV_PORT/login"* ]]
  assert_server_stopped
}

@test "same-origin redirect to an error page: exit 1 names the final status" {
  GAIA_DEV_SMOKE_SERVER_COMMAND="$(server_command 500 /login)"
  export GAIA_DEV_SMOKE_SERVER_COMMAND
  run bash "$SCRIPT" --tree "$TREE" --timeout 30
  [ "$status" -eq 1 ]
  [[ "$output" == *"answered HTTP 500 at http://localhost:$DEV_PORT/login, expected 200"* ]]
  assert_server_stopped
}

# The other origin answers 200, so a smoke that followed it would pass.
@test "redirect to another origin: exit 1 without following it" {
  local other_port=$((DEV_PORT + 150)) other_log="$SCRATCH/other.log"
  (nohup node "$HTTP_FIXTURE" "$other_port" 200 >"$other_log" 2>&1 </dev/null 3>&- & echo $! >"$SCRATCH/other.pid")
  STARTED_PIDS+=("$(cat "$SCRATCH/other.pid")")
  GAIA_DEV_SMOKE_SERVER_COMMAND="$(server_command 200 "http://localhost:$other_port/")"
  export GAIA_DEV_SMOKE_SERVER_COMMAND
  run bash "$SCRIPT" --tree "$TREE" --timeout 30
  [ "$status" -eq 1 ]
  [[ "$output" == *"redirected to http://localhost:$other_port/, outside http://localhost:$DEV_PORT"* ]]
  assert_server_stopped
}

@test "redirect loop: exit 1 after the redirect limit" {
  GAIA_DEV_SMOKE_SERVER_COMMAND="$(server_command 200 /)"
  export GAIA_DEV_SMOKE_SERVER_COMMAND
  run bash "$SCRIPT" --tree "$TREE" --timeout 30
  [ "$status" -eq 1 ]
  [[ "$output" == *"redirected more than 5 times"* ]]
  assert_server_stopped
}

@test "foreign holder: the port is refused with the ask-first message and the holder survives" {
  start_listener "$SCRATCH/elsewhere"
  export GAIA_DEV_SMOKE_SERVER_COMMAND="echo started >$SCRATCH/started; exec sleep 300"
  run bash "$SCRIPT" --tree "$TREE" --timeout 5
  [ "$status" -eq 3 ]
  [[ "$output" == *"port $DEV_PORT, this tree's dev server port, is already in use by PID $LISTENER_PID"* ]]
  [[ "$output" == *"Never stop a process on a port another live tree owns without asking the user first."* ]]
  [ ! -e "$SCRATCH/started" ]
  process_running "$LISTENER_PID"
}

@test "own-tree holder it did not start: refused, and the holder survives" {
  start_listener "$TREE/apps/web"
  export GAIA_DEV_SMOKE_SERVER_COMMAND="echo started >$SCRATCH/started; exec sleep 300"
  run bash "$SCRIPT" --tree "$TREE" --timeout 5
  [ "$status" -eq 3 ]
  [[ "$output" == *"already in use by PID $LISTENER_PID in $TREE"* ]]
  [ ! -e "$SCRATCH/started" ]
  process_running "$LISTENER_PID"
}

# leak_server_from_session <session-id> [<port>]: the leak a subagent leaves.
# A detached, reparented listener in this tree on <port>, default DEV_PORT,
# recorded the way the dev-ports Vite plugin records it: through
# --record-launch with the session id in the environment and that session's
# host registered and alive.
leak_server_from_session() {
  local port="${2:-$DEV_PORT}"
  STATE="$SCRATCH/ports-state"
  export GAIA_PORTS_STATE_DIRECTORY="$STATE"
  mkdir -p "$STATE/sessions"
  bash -c '. "$1"; gaia_server_session_register "$2" "$3" "$4"' _ \
    "$REPO_ROOT/.gaia/scripts/server-process-lib.sh" "$STATE" "$1" "$$"
  start_listener "$TREE/apps/web" "$port"
  CLAUDE_CODE_SESSION_ID="$1" bash "$REPO_ROOT/.gaia/scripts/server-process-lib.sh" \
    --record-launch --pid "$LISTENER_PID" --port "$port" --kind dev --tree "$TREE"
  [ -f "$STATE/launches/$LISTENER_PID.tsv" ]
}

@test "own-tree holder this session launched: stopped, then the smoke test runs" {
  leak_server_from_session session-gate
  export CLAUDE_CODE_SESSION_ID=session-gate
  export GAIA_DEV_SMOKE_SERVER_COMMAND="$(server_command 200)"
  run bash "$SCRIPT" --tree "$TREE" --timeout 20
  [ "$status" -eq 0 ]
  [[ "$output" == *"this Claude session launched in $TREE"* ]]
  process_running "$LISTENER_PID" && return 1
  [ ! -e "$STATE/launches/$LISTENER_PID.tsv" ]
  assert_server_stopped
}

# Each row rewrites one field of the leak's launch record (column number,
# then value), so the record no longer names this session, tree, or a dev
# server.
@test "own-tree holder whose record names another session, tree or kind: refused, and the holder survives" {
  local row column value record attempt
  export CLAUDE_CODE_SESSION_ID=session-gate
  export GAIA_DEV_SMOKE_SERVER_COMMAND="echo started >$SCRATCH/started; exec sleep 300"
  for row in "7 session-other" "10 $SCRATCH/elsewhere" "6 storybook"; do
    column="${row%% *}"
    value="${row#* }"
    leak_server_from_session session-gate
    record="$STATE/launches/$LISTENER_PID.tsv"
    awk -F '\t' -v OFS='\t' -v column="$column" -v value="$value" '{ $column = value; print }' "$record" >"$record.new"
    mv "$record.new" "$record"
    run bash "$SCRIPT" --tree "$TREE" --timeout 5
    [ "$status" -eq 3 ]
    [[ "$output" == *"already in use by PID $LISTENER_PID in $TREE"* ]]
    [ ! -e "$SCRATCH/started" ]
    process_running "$LISTENER_PID"
    [ -f "$record" ]
    kill -KILL "$LISTENER_PID"
    attempt=0
    while port_listening "$DEV_PORT" && [ "$attempt" -lt 50 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
  done
}

@test "this session's dev server on another port: left running while the held port is refused" {
  local other_port_pid
  leak_server_from_session session-gate $((DEV_PORT + 1))
  other_port_pid="$LISTENER_PID"
  start_listener "$TREE/apps/web"
  export CLAUDE_CODE_SESSION_ID=session-gate
  export GAIA_DEV_SMOKE_SERVER_COMMAND="echo started >$SCRATCH/started; exec sleep 300"
  run bash "$SCRIPT" --tree "$TREE" --timeout 5
  [ "$status" -eq 3 ]
  [[ "$output" == *"already in use by PID $LISTENER_PID in $TREE"* ]]
  process_running "$other_port_pid"
}

@test "server exits early: exit 1 says so and prints its output" {
  export GAIA_DEV_SMOKE_SERVER_COMMAND="echo boom-from-server; exit 7"
  run bash "$SCRIPT" --tree "$TREE" --timeout 30
  [ "$status" -eq 1 ]
  [[ "$output" == *"the dev server exited before"* ]]
  [[ "$output" == *"boom-from-server"* ]]
}

@test "never answers: exit 1 at the timeout, and the hung server is stopped" {
  export GAIA_DEV_SMOKE_SERVER_COMMAND="echo \$\$ >$SCRATCH/server.pid; exec sleep 300"
  run bash "$SCRIPT" --tree "$TREE" --timeout 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not answer within 2 seconds"* ]]
  assert_server_stopped
}

@test "usage: a route without a leading slash and a non-numeric timeout exit 2" {
  run bash "$SCRIPT" --tree "$TREE" --path about
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --tree "$TREE" --timeout soon
  [ "$status" -eq 2 ]
}
