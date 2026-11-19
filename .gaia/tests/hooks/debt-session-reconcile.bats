#!/usr/bin/env bats
# Tests for `.claude/hooks/debt-session-reconcile.sh`, the SessionStart hook that
# reconciles a currently-shown `🐛 /gaia-debt` nudge against GitHub on session
# start. It arms the debt-count sentinel when, and only when, the pinned cache
# already shows an open count > 0, so an empty backlog stays fully network-free.
# This backstops a `tech-debt` close that never reached a first-party hook (web
# UI, a teammate, a plain `gh issue close` in a non-hooked shell), which would
# otherwise linger until the 6h TTL.
#
# The hook reads `.gaia/local/debt/count.json` and writes the sentinel under
# the MAIN checkout root (gaia_resolve_main_root), so each test runs it inside
# an isolated sandbox dir that is itself a real git repo -- a SessionStart hook
# always runs inside one in production, and the resolver needs a git layout to
# answer from.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOK_ABSOLUTE_PATH=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/debt-session-reconcile.sh
  command -v jq >/dev/null 2>&1 || skip "jq required"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/.gaia/local/debt"
  git init -q --initial-branch=main "$SANDBOX"
  git -C "$SANDBOX" config user.email gaia-test@example.com
  git -C "$SANDBOX" config user.name "GAIA Test"
  git -C "$SANDBOX" config commit.gpgsign false
  SENTINEL="$SANDBOX/.gaia/local/debt/refresh-requested"
  CACHE="$SANDBOX/.gaia/local/debt/count.json"
}

# write_cache <openCount-json-fragment>: write count.json with the given raw
# openCount value (a number, or a quoted string for the malformed case).
write_cache() {
  printf '{"schema":1,"openCount":%s,"computedAt":1783395838}\n' "$1" > "$CACHE"
}

# run_hook: run the hook from the sandbox, draining a synthetic SessionStart
# payload on stdin.
run_hook() {
  invoke_hook_in "$SANDBOX" '{"hook_event_name":"SessionStart"}' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

@test "openCount 3, openCount 1 and empty stdin with openCount 2 arm the sentinel" {
  local label
  for label in three one empty-stdin; do
    rm -f "$SENTINEL"
    case "$label" in
      three) write_cache 3; run_hook || { echo "case $label: hook failed"; return 1; } ;;
      one) write_cache 1; run_hook || { echo "case $label: hook failed"; return 1; } ;;
      empty-stdin)
        write_cache 2
        invoke_hook_in "$SANDBOX" "" "$HOOK_ABSOLUTE_PATH"
        [ "$status" -eq 0 ] || { echo "case $label: status=$status"; return 1; }
        ;;
    esac
    [ -f "$SENTINEL" ] || { echo "case $label: sentinel not armed"; return 1; }
  done
}

@test "openCount 0, a missing cache and a malformed openCount leave the sentinel unset" {
  local label
  for label in zero missing malformed; do
    rm -f "$SENTINEL" "$CACHE"
    case "$label" in
      zero) write_cache 0 ;;
      missing) ;;
      malformed) write_cache '"abc"' ;;
    esac
    run_hook || { echo "case $label: hook failed"; return 1; }
    [ ! -f "$SENTINEL" ] || { echo "case $label: sentinel armed"; return 1; }
  done
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}
