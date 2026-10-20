#!/usr/bin/env bats

# .claude/hooks/state-reaper-session-start.sh: the SessionStart hook that
# launches the backstop reaper detached, at most once per 24 hours, from any
# tree. Every case builds a fixture main checkout (and, where it matters, a
# linked worktree whose .gaia/local is a symlink to main's) under
# $BATS_TEST_TMPDIR. The launched reaper is a sleeping stub that appends a
# launch marker, except in the end-to-end cases, which copy the real reaper,
# its libraries and the committed registry. gh and curl stubs that record a
# call sit first on PATH in every case.
#
# Each guard is proven able to fail on a scratch edit of the hook with that
# check removed (the stamp gate, the lock, the main-root resolution).
#
# Run via: bash .gaia/scripts/bats5.sh .gaia/tests/hooks/state-reaper-session-start.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# Single-quoted mutation literals and generated stubs keep their `$` for the
# hook; MAIN is reassigned in one test on purpose and read by helpers.
# shellcheck disable=SC2016,SC2030,SC2031

bats_require_minimum_version 1.5.0

REAPER_FILES="state-reaper.sh state-reaper-lib.sh state-reaper-classes.sh main-root-lib.sh state-registry-lib.sh branch-name-lib.sh audit-key-lib.sh audit-loop-state-lib.sh"
HOOK_NAME="state-reaper-session-start.sh"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v git >/dev/null 2>&1 || skip "git required"
  command -v perl >/dev/null 2>&1 || skip "perl required"
  REAL_GIT="$(command -v git)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  TREE="$TEMPORARY_DIRECTORY/tree"
  LOCAL="$MAIN/.gaia/local"
  STATE_DIRECTORY="$LOCAL/cache/state-reaper"
  STAMP="$STATE_DIRECTORY/last-launch"
  LOCK="$STATE_DIRECTORY/launch.lock.d"
  LAUNCH_MARKER="$LOCAL/launch-marker"
  LAUNCH_DONE="$LOCAL/launch-done"
  NETWORK_MARKER="$TEMPORARY_DIRECTORY/network-called"
  STUB_BIN="$TEMPORARY_DIRECTORY/stub-bin"
  mkdir -p "$STUB_BIN"
  local tool
  for tool in gh curl; do
    printf '#!/bin/sh\nprintf "%s\\n" "$0" >> "%s"\nexit 1\n' "$tool" "$NETWORK_MARKER" >"$STUB_BIN/$tool"
    chmod +x "$STUB_BIN/$tool"
  done
  unset GITHUB_ACTIONS GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
}

teardown() {
  [ ! -e "$NETWORK_MARKER" ] || {
    printf 'the hook reached the network:\n' >&2
    cat "$NETWORK_MARKER" >&2
    return 1
  }
}

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }

modification_time() { perl -e 'print((stat $ARGV[0])[9])' "$1"; }

# stamp_at <hours> <path>: sets the path's mtime that many hours ago. BSD and
# GNU safe.
age_path() {
  local epoch=$(($(date +%s) - $1 * 3600 - 120)) value
  value="$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M.%S)"
  touch -t "$value" "$2"
}

age_minutes() {
  local epoch=$(($(date +%s) - $1 * 60)) value
  value="$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M.%S)"
  touch -t "$value" "$2"
}

# wait_for_file <path> [tenths-of-a-second]: bounded poll.
wait_for_file() {
  local tries="${2:-50}"
  while [ "$tries" -gt 0 ]; do
    [ -e "$1" ] && return 0
    sleep 0.1
    tries=$((tries - 1))
  done
  printf 'timed out waiting for %s\n' "$1" >&2
  return 1
}

launch_count() {
  if [ -f "$LAUNCH_MARKER" ]; then
    wc -l <"$LAUNCH_MARKER" | tr -d ' '
  else
    printf '0\n'
  fi
}

# write_stub_reaper: a reaper that records its launch under main's .gaia/local
# and then sleeps, so a hook that waited for it would show in the timing.
write_stub_reaper() {
  mkdir -p "$MAIN/.gaia/scripts"
  cat >"$MAIN/.gaia/scripts/state-reaper.sh" <<'STUB'
#!/bin/sh
local_directory="$(dirname "$0")/../local"
printf 'launched\n' >> "$local_directory/launch-marker"
sleep 3
printf 'done\n' >> "$local_directory/launch-done"
STUB
}

# make_fixture [stub|real]: a committed main checkout holding the hook, the
# main-root library and either the stub reaper or the real reaper with its
# libraries and the committed registry. .gaia/local is created after the
# commit, so it is untracked.
make_fixture() {
  local file
  mkdir -p "$MAIN/.claude/hooks" "$MAIN/.gaia/scripts"
  cp "$REPO_ROOT/.claude/hooks/$HOOK_NAME" "$MAIN/.claude/hooks/$HOOK_NAME"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$MAIN/.gaia/scripts/main-root-lib.sh"
  if [ "${1:-stub}" = real ]; then
    for file in $REAPER_FILES; do
      cp "$REPO_ROOT/.gaia/scripts/$file" "$MAIN/.gaia/scripts/$file"
    done
    cp "$REPO_ROOT/.gaia/state-registry.json" "$MAIN/.gaia/state-registry.json"
  else
    write_stub_reaper
  fi
  "$REAL_GIT" -C "$MAIN" init -q
  "$REAL_GIT" -C "$MAIN" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" -C "$MAIN" config user.email fixture@example.com
  "$REAL_GIT" -C "$MAIN" config user.name fixture
  "$REAL_GIT" -C "$MAIN" add -A
  "$REAL_GIT" -C "$MAIN" commit -q -m fixture
  mkdir -p "$STATE_DIRECTORY"
}

# make_linked_tree: a linked worktree whose .gaia/local is a symlink to
# main's, as the worktree provisioning makes it.
make_linked_tree() {
  "$REAL_GIT" -C "$MAIN" worktree add -q "$TREE" -b linked-tree
  ln -s "$LOCAL" "$TREE/.gaia/local"
}

# run_hook <tree>: the hook as the harness runs it, from that tree's own copy,
# with no stdin and the network stubs first on PATH. 3>&- keeps the detached
# reaper from holding bats' output descriptor.
run_hook() {
  run env PATH="$STUB_BIN:$PATH" bash -c 'cd "$1" && exec bash "$1/.claude/hooks/'"$HOOK_NAME"'" </dev/null 3>&-' _ "$1"
}

# mutate_hook <old> <new> [all]: rewrites the fixture's hook with the first
# (or every) occurrence of a literal replaced, and fails when nothing changed.
mutate_hook() {
  local hook="$MAIN/.claude/hooks/$HOOK_NAME" content mutated
  content="$(cat "$hook")"
  if [ "${3:-}" = all ]; then
    mutated="${content//"$1"/"$2"}"
  else
    mutated="${content/"$1"/"$2"}"
  fi
  if [ "$mutated" = "$content" ]; then
    printf 'mutation did not apply: %s\n' "$1" >&2
    return 1
  fi
  printf '%s\n' "$mutated" >"$hook"
}

# ---------- launch cadence ----------

# bats test_tags=whole-tree
@test "a stamp 2 hours old launches nothing from the main checkout or a linked tree and leaves the stamp alone" {
  make_fixture
  make_linked_tree
  touch "$STAMP"
  age_path 2 "$STAMP"
  local before
  before="$(modification_time "$STAMP")"
  run_hook "$MAIN"
  [ "$status" -eq 0 ]
  run_hook "$TREE"
  [ "$status" -eq 0 ]
  sleep 0.5
  [ "$(launch_count)" -eq 0 ]
  [ "$(modification_time "$STAMP")" = "$before" ]
}

# bats test_tags=whole-tree
@test "a stamp 25 hours old launches the stub once from each tree, restamps main's, and returns while the stub sleeps" {
  make_fixture
  make_linked_tree
  local tree start finish expected=0
  for tree in "$MAIN" "$TREE"; do
    touch "$STAMP"
    age_path 25 "$STAMP"
    rm -f "$LAUNCH_DONE"
    start="$(now_ms)"
    run_hook "$tree"
    finish="$(now_ms)"
    [ "$status" -eq 0 ]
    [ $((finish - start)) -lt 2000 ]
    expected=$((expected + 1))
    wait_for_file "$LAUNCH_MARKER"
    local tries=50
    while [ "$(launch_count)" -lt "$expected" ] && [ "$tries" -gt 0 ]; do
      sleep 0.1
      tries=$((tries - 1))
    done
    [ "$(launch_count)" -eq "$expected" ]
    [ ! -e "$LAUNCH_DONE" ]
    [ -z "$(find "$STAMP" -maxdepth 0 -mmin +1)" ]
  done
  sleep 3.5
}

# bats test_tags=whole-tree
@test "a missing stamp launches" {
  make_fixture
  run_hook "$MAIN"
  [ "$status" -eq 0 ]
  wait_for_file "$LAUNCH_MARKER"
  [ -f "$STAMP" ]
  sleep 3.5
}

# bats test_tags=whole-tree
@test "red state: without the stamp gate a 2-hour-old stamp launches" {
  make_fixture
  mutate_hook 'stamp_is_fresh && exit 0' ':' all
  touch "$STAMP"
  age_path 2 "$STAMP"
  run_hook "$MAIN"
  [ "$status" -eq 0 ]
  wait_for_file "$LAUNCH_MARKER"
  sleep 3.5
}

# ---------- single flight ----------

# bats test_tags=whole-tree
@test "two concurrent starts against a stale stamp launch exactly one reaper" {
  make_fixture
  touch "$STAMP"
  age_path 25 "$STAMP"
  local hook="$MAIN/.claude/hooks/$HOOK_NAME"
  (cd "$MAIN" && PATH="$STUB_BIN:$PATH" exec bash "$hook" </dev/null >/dev/null 2>&1 3>&-) &
  local first=$!
  (cd "$MAIN" && PATH="$STUB_BIN:$PATH" exec bash "$hook" </dev/null >/dev/null 2>&1 3>&-) &
  local second=$!
  wait "$first" "$second"
  wait_for_file "$LAUNCH_MARKER"
  sleep 1
  [ "$(launch_count)" -eq 1 ]
  sleep 3
}

# bats test_tags=whole-tree
@test "a held fresh lock launches nothing" {
  make_fixture
  mkdir "$LOCK"
  run_hook "$MAIN"
  [ "$status" -eq 0 ]
  sleep 0.5
  [ "$(launch_count)" -eq 0 ]
  [ -d "$LOCK" ]
}

# bats test_tags=whole-tree
@test "a lock older than 10 minutes is reclaimed and the reaper launches" {
  make_fixture
  mkdir "$LOCK"
  age_minutes 11 "$LOCK"
  run_hook "$MAIN"
  [ "$status" -eq 0 ]
  wait_for_file "$LAUNCH_MARKER"
  [ ! -e "$LOCK" ]
  sleep 3.5
}

# bats test_tags=whole-tree
@test "red state: without the lock a held fresh lock does not stop a launch" {
  make_fixture
  mutate_hook 'if ! mkdir "$lock_directory" 2>/dev/null; then' 'if ! true; then'
  mkdir "$LOCK"
  run_hook "$MAIN"
  [ "$status" -eq 0 ]
  wait_for_file "$LAUNCH_MARKER"
  sleep 3.5
}

# ---------- fail open ----------

# bats test_tags=whole-tree
@test "outside any repository the hook exits 0 and launches nothing" {
  local bare="$TEMPORARY_DIRECTORY/bare"
  mkdir -p "$bare/.claude/hooks" "$bare/.gaia/scripts"
  cp "$REPO_ROOT/.claude/hooks/$HOOK_NAME" "$bare/.claude/hooks/"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$bare/.gaia/scripts/"
  MAIN="$bare"
  write_stub_reaper
  run_hook "$bare"
  [ "$status" -eq 0 ]
  sleep 0.5
  [ ! -e "$bare/.gaia/local/launch-marker" ]
  [ ! -e "$bare/.gaia/local/cache/state-reaper/last-launch" ]
}

# bats test_tags=whole-tree
@test "red state: without the main-root resolution a run outside any repository launches the cwd's reaper" {
  local bare="$TEMPORARY_DIRECTORY/bare"
  mkdir -p "$bare/.claude/hooks" "$bare/.gaia/scripts"
  cp "$REPO_ROOT/.claude/hooks/$HOOK_NAME" "$bare/.claude/hooks/"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$bare/.gaia/scripts/"
  MAIN="$bare"
  write_stub_reaper
  mutate_hook 'main_root="$(gaia_resolve_main_root 2>/dev/null)" || exit 0' 'main_root="$(gaia_resolve_main_root 2>/dev/null)" || main_root="$PWD"'
  run_hook "$bare"
  [ "$status" -eq 0 ]
  wait_for_file "$bare/.gaia/local/launch-marker"
  sleep 3.5
}

# bats test_tags=whole-tree
@test "an absent reaper script exits 0, launches nothing and leaves the stamp alone" {
  make_fixture
  rm "$MAIN/.gaia/scripts/state-reaper.sh"
  run_hook "$MAIN"
  [ "$status" -eq 0 ]
  [ ! -e "$STAMP" ]
  [ ! -e "$LOCK" ]
}

# bats test_tags=whole-tree
@test "an unwritable cache exits 0 and launches nothing" {
  make_fixture
  rmdir "$STATE_DIRECTORY"
  rmdir "$LOCAL/cache"
  printf 'not a directory\n' >"$LOCAL/cache"
  run_hook "$MAIN"
  [ "$status" -eq 0 ]
  sleep 0.5
  [ "$(launch_count)" -eq 0 ]
}

# ---------- end to end with the real reaper ----------

# plant_json <relative> <json> <days>
plant_json() {
  mkdir -p "$(dirname "$LOCAL/$1")"
  printf '%s\n' "$2" >"$LOCAL/$1"
  age_path $(($3 * 24)) "$LOCAL/$1"
}

# plant_directory <relative> <days>
plant_directory() {
  mkdir -p "$LOCAL/$1"
  printf 'content\n' >"$LOCAL/$1/inner"
  age_path $(($2 * 24)) "$LOCAL/$1/inner"
  age_path $(($2 * 24)) "$LOCAL/$1"
}

# plant_protected <key> <pull-request> <days>: the audit-loop state, its closed
# archive and the verify-pass record one branch key owns.
plant_protected() {
  local key="$1" plus="${1//\//+}" pull_request="$2" days="$3"
  plant_json "protected/audit-loop/$key.json" "{\"pr\":$pull_request}" "$days"
  plant_directory "protected/audit-loop/$key.d" "$days"
  plant_json "protected/audit-loop/.closed/$plus.$pull_request.20260101T000000Z.json" "{\"pr\":$pull_request}" "$days"
  plant_directory "protected/audit-loop/.closed/$plus.$pull_request.20260101T000000Z.d" "$days"
  plant_json "protected/verify-pass/$key.json" '{}' "$days"
}

protected_paths() {
  local key="$1" plus="${1//\//+}" pull_request="$2"
  printf '%s\n' \
    "protected/audit-loop/$key.json" \
    "protected/audit-loop/$key.d" \
    "protected/audit-loop/.closed/$plus.$pull_request.20260101T000000Z.json" \
    "protected/audit-loop/.closed/$plus.$pull_request.20260101T000000Z.d" \
    "protected/verify-pass/$key.json"
}

assert_paths() {
  local mode="$1" path count=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    count=$((count + 1))
    if [ "$mode" = present ]; then
      [ -e "$LOCAL/$path" ] || {
        printf 'expected present: %s\n' "$path" >&2
        return 1
      }
    else
      [ ! -e "$LOCAL/$path" ] || {
        printf 'expected removed: %s\n' "$path" >&2
        return 1
      }
    fi
  done <<<"$2"
  [ "$count" -eq 5 ]
}

wait_for_record() { wait_for_file "$STATE_DIRECTORY/last-run.json" 200; }

# bats test_tags=whole-tree
@test "the hook drives the real reaper: a gone branch's protected state goes, live branch and worktree state stay" {
  make_fixture real
  "$REAL_GIT" -C "$MAIN" branch fix/x
  "$REAL_GIT" -C "$MAIN" worktree add -q "$TEMPORARY_DIRECTORY/wt-foo" -b worktree-foo
  local window
  window="$(jq -r '.entries[] | select(.id == "audit-loop-state") | .retention.days' "$REPO_ROOT/.gaia/state-registry.json")"
  [ "$window" -ge 2 ]
  mkdir -p "$LOCAL/telemetry"
  printf '{"kind":"merge","pr":78}\n' >"$LOCAL/telemetry/links.jsonl"
  plant_protected fix/y 78 $((window + 1))
  plant_protected fix/x 79 $((window + 1))
  plant_protected foo 80 $((window + 1))
  touch "$STAMP"
  age_path 25 "$STAMP"
  run_hook "$MAIN"
  [ "$status" -eq 0 ]
  wait_for_record
  assert_paths absent "$(protected_paths fix/y 78)"
  assert_paths present "$(protected_paths fix/x 79)"
  assert_paths present "$(protected_paths foo 80)"
}

# bats test_tags=whole-tree
@test "failed git reads and a malformed registry: the hook still launches the reaper and no keyed entry is removed" {
  make_fixture real
  printf '{ not json\n' >"$MAIN/.gaia/state-registry.json"
  mkdir -p "$MAIN/bin"
  cat >"$MAIN/bin/git" <<EOF
#!/bin/sh
case " \$* " in *" worktree list "* | *" for-each-ref "*) exit 1 ;; esac
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$MAIN/bin/git"
  local window
  window="$(jq -r '.entries[] | select(.id == "audit-loop-state") | .retention.days' "$REPO_ROOT/.gaia/state-registry.json")"
  plant_protected fix/y 78 $((window + 1))
  plant_json "cache/gh-artifact-pr.fix-gone.json" '{}' 30
  touch "$STAMP"
  age_path 25 "$STAMP"
  run env PATH="$MAIN/bin:$STUB_BIN:$PATH" bash -c 'cd "$1" && exec bash "$1/.claude/hooks/'"$HOOK_NAME"'" </dev/null 3>&-' _ "$MAIN"
  [ "$status" -eq 0 ]
  wait_for_record
  [ -z "$(find "$STAMP" -maxdepth 0 -mmin +1)" ]
  assert_paths present "$(protected_paths fix/y 78)"
  [ -e "$LOCAL/cache/gh-artifact-pr.fix-gone.json" ]
}

# ---------- registration ----------

@test "the tracked hook is executable" {
  [ -x "$REPO_ROOT/.claude/hooks/$HOOK_NAME" ]
}

# assert_registered <settings>: the SessionStart startup|resume group names the
# hook.
assert_registered() {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
  hook_registered "$1" '.hooks.SessionStart[] | select(.matcher == "startup|resume")' "$HOOK_NAME"
}

# bats test_tags=whole-tree
@test "both settings files register the hook in the SessionStart startup|resume group" {
  assert_registered "$REPO_ROOT/.claude/settings.json"
  assert_registered "$REPO_ROOT/frontend/.claude/settings.json"
}

# bats test_tags=whole-tree
@test "red state: a settings copy without the entry no longer registers the hook" {
  local mutant="$TEMPORARY_DIRECTORY/settings-mutant.json"
  jq --arg name "$HOOK_NAME" '.hooks.SessionStart |= map(.hooks |= map(select(.command | contains($name) | not)))' \
    "$REPO_ROOT/.claude/settings.json" >"$mutant"
  cmp -s "$mutant" "$REPO_ROOT/.claude/settings.json" && return 1
  run assert_registered "$mutant"
  [ "$status" -ne 0 ]
}
