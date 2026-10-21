#!/usr/bin/env bats
# Tests for which trees the kept-worktree reminder (.gaia/scripts/kept-worktrees.sh)
# counts as orphaned and lists: merged, not held by a live Claude session, and
# not the starting session's own tree. Unknown on any term means not listed.
#
# Liveness reads the host record ports-session-start.sh writes
# (<main>/.gaia/local/ports/sessions/<id>.tsv) and the occupancy record
# provisioning writes through `kept-worktrees.sh occupy`. A live host is a
# background `sleep` whose identity is recorded the way the ports library
# records a session host. Merge confirmation for a squash-merged [gone] tree
# comes from a detached `gh` lookup, stubbed here on PATH.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  # shellcheck source=.gaia/scripts/tests/helpers/kept-worktrees-fixture.sh
  . "$BATS_TEST_DIRNAME/helpers/kept-worktrees-fixture.sh"
  kept_worktrees_setup
  HOST_PIDS=""
  GH_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  MERGED_CACHE="$MAIN/.gaia/local/cache/shared/kept-worktrees-merged.tsv"
}

teardown() {
  local pid
  for pid in $HOST_PIDS; do kill "$pid" 2>/dev/null; done
  return 0
}

# live_session <session id> <tree>: a live host process recorded for the
# session, and the session's occupancy of the tree.
live_session() {
  local pid identity
  sleep 600 &
  pid=$!
  HOST_PIDS="$HOST_PIDS $pid"
  identity=$(bash -c '. "$1"; gaia_server_process_identity "$2"' _ "$SCRIPTS/server-process-lib.sh" "$pid") || return 1
  mkdir -p "$MAIN/.gaia/local/ports/sessions" || return 1
  printf '%s\t%s\t%s\n' "$pid" "$identity" "$(date +%s)" >"$MAIN/.gaia/local/ports/sessions/$1.tsv"
  run bash "$KEPT" occupy --session "$1" --tree "$2"
  [ -f "$MAIN/.gaia/local/worktree-occupancy/$1.tsv" ] || { echo "no occupancy written"; return 1; }
  LAST_HOST_PID=$pid
}

# squash_merged_gone: the tree's branch gains a commit, main gets the same
# change as a different commit (a squash), and the remote branch is deleted,
# so the branch reads [gone] and its tip is not an ancestor of main.
squash_merged_gone() {
  printf 'feature\n' >"$TREE/feature" || return 1
  git -C "$TREE" add feature || return 1
  git -C "$TREE" commit -q -m feature || return 1
  git -C "$TREE" push -q 2>/dev/null || return 1
  printf 'feature\n' >"$MAIN/feature" || return 1
  git -C "$MAIN" add feature || return 1
  git -C "$MAIN" commit -q -m "feature (squash)" || return 1
  git -C "$MAIN" push -q origin main 2>/dev/null || return 1
  gone_upstream || return 1
  TIP=$(git -C "$TREE" rev-parse HEAD)
}

# stub_gh <exit status> [printed head sha]: a gh on PATH that logs each call
# and answers `gh pr list ... --jq` with the given sha.
stub_gh() {
  mkdir -p "$BATS_TEST_TMPDIR/gh-bin" || return 1
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n[ -n "%s" ] && printf "%%s\\n" "%s"\nexit %s\n' \
    "$GH_LOG" "${2:-}" "${2:-}" "$1" >"$BATS_TEST_TMPDIR/gh-bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/gh-bin/gh"
  PATH="$BATS_TEST_TMPDIR/gh-bin:$PATH"
  export PATH
}

# wait_for <path>: up to five seconds for the detached lookup to write it.
wait_for() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    [ -s "$1" ] && return 0
    sleep 0.2
  done
  return 1
}

listed() { printf '%s\n' "$output" | grep -Fq -- "- $TREE "; }

# --- live sessions ---

@test "a kept tree a live session occupies is not listed, and is counted" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  live_session 11111111-aaaa-bbbb-cccc-000000000001 "$TREE" || return 1
  remind
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  listed && { printf 'listed: %s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "1 more kept worktree(s) not listed" || { printf '%s\n' "$output"; return 1; }
}

@test "red twin: a reminder that never reads occupancy lists a live session's tree" {
  mutate kept-worktrees.sh -e 's/^      held) held_count=\$((held_count + 1)); continue ;;$/      held) ;;/' || return 1
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  live_session 11111111-aaaa-bbbb-cccc-000000000001 "$TREE" || return 1
  remind
  listed || { printf 'stayed green: %s\n' "$output"; return 1; }
}

@test "an occupancy whose host has exited is pruned and the tree is listed" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  live_session 11111111-aaaa-bbbb-cccc-000000000002 "$TREE" || return 1
  kill "$LAST_HOST_PID"
  wait "$LAST_HOST_PID" 2>/dev/null || true
  remind
  listed || { printf '%s\n' "$output"; return 1; }
  [ -e "$MAIN/.gaia/local/worktree-occupancy/11111111-aaaa-bbbb-cccc-000000000002.tsv" ] && { echo "not pruned"; return 1; }
  true
}

@test "a reused pid (start time differs) counts as an exited host" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  live_session 11111111-aaaa-bbbb-cccc-000000000003 "$TREE" || return 1
  printf '%s\tMon Jan  1 00:00:00 2001\tclaude\t1\n' "$LAST_HOST_PID" >"$MAIN/.gaia/local/ports/sessions/11111111-aaaa-bbbb-cccc-000000000003.tsv"
  remind
  listed || { printf '%s\n' "$output"; return 1; }
}

@test "an occupancy with no readable host record counts as held" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  run bash "$KEPT" occupy --session 11111111-aaaa-bbbb-cccc-000000000004 --tree "$TREE"
  remind
  listed && { printf 'listed: %s\n' "$output"; return 1; }
  [ -f "$MAIN/.gaia/local/worktree-occupancy/11111111-aaaa-bbbb-cccc-000000000004.tsv" ] || { echo "unknown occupancy was pruned"; return 1; }
}

@test "red twin: reading an unknown host as exited lists the tree" {
  mutate kept-worktrees.sh -e 's/^  \[ -f "\$host_record" \] || { printf unknown; return 0; }$/  [ -f "$host_record" ] || { printf dead; return 0; }/' || return 1
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  run bash "$KEPT" occupy --session 11111111-aaaa-bbbb-cccc-000000000004 --tree "$TREE"
  remind
  listed || { printf 'stayed green: %s\n' "$output"; return 1; }
}

@test "without the process library every occupied tree counts as held" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  live_session 11111111-aaaa-bbbb-cccc-000000000005 "$TREE" || return 1
  kill "$LAST_HOST_PID"
  wait "$LAST_HOST_PID" 2>/dev/null || true
  rm -f "$SCRIPTS/server-process-lib.sh"
  remind
  [ "$status" -eq 0 ] || return 1
  listed && { printf 'listed: %s\n' "$output"; return 1; }
  true
}

@test "an occupancy naming another tree does not hold this one" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  live_session 11111111-aaaa-bbbb-cccc-000000000006 "$MAIN" || return 1
  remind
  listed || { printf '%s\n' "$output"; return 1; }
}

@test "occupy rejects a session id that is not a plain token" {
  run bash "$KEPT" occupy --session "../escape" --tree "$TREE"
  [ "$status" -eq 0 ] || return 1
  [ -e "$MAIN/.gaia/local/escape.tsv" ] && return 1
  [ -d "$MAIN/.gaia/local/worktree-occupancy" ] && [ -n "$(ls "$MAIN/.gaia/local/worktree-occupancy")" ] && return 1
  true
}

# --- the session's own tree ---

@test "the starting session's own tree is never listed" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  run bash "$KEPT" remind --main-root "$MAIN" --own-tree "$TREE"
  [ "$status" -eq 0 ] || return 1
  listed && { printf 'listed: %s\n' "$output"; return 1; }
  true
}

@test "red twin: a reminder without the own-tree check lists the session's own tree" {
  mutate kept-worktrees.sh -e 's/^    \[ -n "\$own_tree" \] && \[ "\$tree" = "\$own_tree" \] && continue$/    :/' || return 1
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  run bash "$KEPT" remind --main-root "$MAIN" --own-tree "$TREE"
  listed || { printf 'stayed green: %s\n' "$output"; return 1; }
}

# --- merged ---

@test "a [gone] tree whose tip is on the default branch is listed without gh" {
  stub_gh 0
  gone_upstream || return 1
  remind
  listed || { printf '%s\n' "$output"; return 1; }
  [ -s "$GH_LOG" ] && { echo "gh was called"; return 1; }
  true
}

@test "a squash-merged [gone] tree is not listed until the lookup confirms it, then is" {
  squash_merged_gone || return 1
  stub_gh 0 "$TIP"
  remind
  listed && { printf 'listed before confirmation: %s\n' "$output"; return 1; }
  wait_for "$MERGED_CACHE" || { echo "the lookup never wrote the cache"; cat "$GH_LOG" 2>/dev/null; return 1; }
  grep -Fq -- "--head $BRANCH" "$GH_LOG" || { cat "$GH_LOG"; return 1; }
  remind
  listed || { printf 'not listed after confirmation: %s\n' "$output"; return 1; }
}

@test "red twin: a reminder that skips the merge check lists an unconfirmed squash tree" {
  mutate kept-worktrees.sh -e 's/^        \*) unconfirmed=true; continue ;;$/        *) ;;/' || return 1
  squash_merged_gone || return 1
  stub_gh 1
  remind
  listed || { printf 'stayed green: %s\n' "$output"; return 1; }
}

@test "a PR merged from a different head sha does not confirm the tree" {
  squash_merged_gone || return 1
  stub_gh 0 0000000000000000000000000000000000000000
  remind
  wait_for "$GH_LOG" || return 1
  sleep 1
  [ -s "$MERGED_CACHE" ] && { cat "$MERGED_CACHE"; return 1; }
  remind
  listed && { printf 'listed: %s\n' "$output"; return 1; }
  true
}

@test "an unmerged [gone] tree is never listed" {
  printf 'feature\n' >"$TREE/feature"
  git -C "$TREE" add feature
  git -C "$TREE" commit -q -m feature
  git -C "$TREE" push -q 2>/dev/null
  gone_upstream || return 1
  stub_gh 0
  remind
  listed && { printf 'listed: %s\n' "$output"; return 1; }
  true
}

@test "the lookup runs at most once per interval" {
  squash_merged_gone || return 1
  stub_gh 0
  remind
  wait_for "$GH_LOG" || return 1
  remind
  remind
  sleep 1
  [ "$(grep -c '' "$GH_LOG")" -eq 1 ] || { cat "$GH_LOG"; return 1; }
}

@test "red twin: without the interval check every reminder spawns a lookup" {
  mutate kept-worktrees.sh -e 's/^  lookup_fresh "\$1" && return 0$/  :/' || return 1
  squash_merged_gone || return 1
  stub_gh 0
  remind
  wait_for "$GH_LOG" || return 1
  remind
  sleep 1
  [ "$(grep -c '' "$GH_LOG")" -ge 2 ] || { printf 'stayed green\n'; cat "$GH_LOG"; return 1; }
}

@test "an unauthenticated gh is quiet: no output, no cache, exit 0" {
  squash_merged_gone || return 1
  stub_gh 4
  remind
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || { printf '%s\n' "$output"; return 1; }
  wait_for "$GH_LOG" || return 1
  sleep 1
  [ -e "$MERGED_CACHE" ] && { cat "$MERGED_CACHE"; return 1; }
  true
}

@test "a missing gh is quiet: the lookup exits without a cache" {
  squash_merged_gone || return 1
  run env PATH=/nonexistent "$BASH" "$KEPT" lookup-merged --main-root "$MAIN"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || { printf '%s\n' "$output"; return 1; }
  [ -e "$MERGED_CACHE" ] && return 1
  true
}

# --- output ---

@test "a listed tree carries its last-commit age and the confirm-each instruction" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  remind
  printf '%s\n' "$output" | grep -Eq -- "^- $TREE \(branch $BRANCH, last commit [^)]+\): uncommitted changes$" || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "remove a listed tree only when the user names that tree" || { printf '%s\n' "$output"; return 1; }
}

# --- provisioning records occupancy ---

# provision_enter <hook path>: runs the provisioning hook on an EnterWorktree
# payload for TREE, with the ports stage off, and sets OCCUPANCY to what it
# recorded for the session.
provision_enter() {
  local payload
  payload=$(printf '{"hook_event_name":"PostToolUse","tool_name":"EnterWorktree","session_id":"22222222-aaaa-bbbb-cccc-000000000001","cwd":"%s","tool_response":{"worktreePath":"%s"}}' "$TREE" "$TREE")
  run bash "$1" <<<"$payload"
  OCCUPANCY=$(cat "$MAIN/.gaia/local/worktree-occupancy/22222222-aaaa-bbbb-cccc-000000000001.tsv" 2>/dev/null) || OCCUPANCY=""
}

@test "provisioning on EnterWorktree records the session's occupancy" {
  provision_enter "$REPO_ROOT/.claude/hooks/provision-worktree.sh"
  [ "$OCCUPANCY" = "$TREE" ] || { printf '%s\n' "$output"; return 1; }
}

@test "red twin: provisioning without the occupy call records nothing" {
  local stage="$BATS_TEST_TMPDIR/hook-stage"
  mkdir -p "$stage/.claude/hooks" "$stage/.gaia" || return 1
  ln -s "$REPO_ROOT/.gaia/scripts" "$stage/.gaia/scripts" || return 1
  sed -e '/kept_worktrees_script" occupy/d' "$REPO_ROOT/.claude/hooks/provision-worktree.sh" >"$stage/.claude/hooks/provision-worktree.sh" || return 1
  cmp -s "$stage/.claude/hooks/provision-worktree.sh" "$REPO_ROOT/.claude/hooks/provision-worktree.sh" && { echo "the mutation changed nothing"; return 1; }
  provision_enter "$stage/.claude/hooks/provision-worktree.sh"
  [ -z "$OCCUPANCY" ] || { printf 'stayed green: %s\n' "$OCCUPANCY"; return 1; }
}
