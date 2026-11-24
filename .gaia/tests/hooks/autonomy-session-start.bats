#!/usr/bin/env bats
#
# Suite for .claude/hooks/autonomy-session-start.sh: the unattended-run notice
# appears only while the autonomy switch is live.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/autonomy-session-start.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK="${HOOK_UNDER_TEST:-$REPO_ROOT/.claude/hooks/autonomy-session-start.sh}"
  FIX=$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/fix.XXXXXX")" && pwd -P)
  MAIN="$FIX/main"
  WORKTREE="$FIX/wt"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  git -C "$MAIN" worktree add -q "$WORKTREE" -b feat
  mkdir -p "$MAIN/.gaia/local/protected" "$WORKTREE/.gaia"
  ln -s "$MAIN/.gaia/local" "$WORKTREE/.gaia/local"
  SWITCH="$MAIN/.gaia/local/protected/autonomy.json"
}

# start [cwd]: run the hook on a startup payload for the cwd (default: main).
start() {
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "{\"session_id\":\"s\",\"source\":\"startup\",\"cwd\":\"${1:-$MAIN}\"}" "$HOOK"
}

# bats test_tags=protected
@test "the notice appears, with the expiry and may_merge, only while the switch is live" {
  local expires_at text
  echo "case: no switch"
  start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo "case: switch disabled"
  jq -n '{enabled: false, expires_at: (now + 3600 | todate), may_merge: true}' >"$SWITCH"
  start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo "case: switch expired"
  jq -n '{enabled: true, expires_at: (now - 1 | todate), may_merge: true}' >"$SWITCH"
  start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo "case: switch live, session in a linked worktree"
  jq -n '{enabled: true, expires_at: (now + 3600 | todate), may_merge: true}' >"$SWITCH"
  expires_at=$(jq -r .expires_at "$SWITCH")
  start "$WORKTREE"
  [ "$status" -eq 0 ]
  text=$(jq -r .systemMessage <<<"$output")
  [ "$(jq -r .hookSpecificOutput.additionalContext <<<"$output")" = "$text" ]
  [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" = SessionStart ]
  [[ $text == "GAIA unattended run: the autonomy switch $SWITCH is live until $expires_at (UTC)"*"may_merge is true."* ]]
}

@test "with no payload the working directory stands in, and a missing library exits 0 silently" {
  jq -n '{enabled: true, expires_at: (now + 3600 | todate), may_merge: false}' >"$SWITCH"
  echo "case: no payload, run from the main checkout, so the working directory stands in"
  run bash -c 'cd "$2" && printf "" | bash "$1"' _ "$HOOK" "$MAIN"
  [ "$status" -eq 0 ]
  [[ $output == *'"systemMessage":"GAIA unattended run'* ]]
  echo "case: library missing"
  local copy="$FIX/copy/.claude/hooks"
  mkdir -p "$copy"
  cp "$HOOK" "$copy/"
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "{\"cwd\":\"$MAIN\"}" "$copy/autonomy-session-start.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=protected
@test "a symlinked .gaia/local in the main checkout reads as off" {
  local outside="$FIX/outside"
  mkdir -p "$outside/protected"
  jq -n '{enabled: true, expires_at: (now + 3600 | todate), may_merge: true}' >"$outside/protected/autonomy.json"
  rm -rf "$MAIN/.gaia/local"
  ln -s "$outside" "$MAIN/.gaia/local"
  start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
