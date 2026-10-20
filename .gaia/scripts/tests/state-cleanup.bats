#!/usr/bin/env bats
#
# The post-merge cleanup verb: it removes a merged branch's own audit, run and
# PR-cache state from .gaia/local, and keeps everything else.
#
# Every case builds its own main checkout under $BATS_TEST_TMPDIR holding
# copies of the verb, its libraries and the committed registry, so nothing
# here reaches the real .gaia/local. Every removal case plants an open
# branch's state beside the merged branch's, so a survivor proves the rule
# rather than a verb that deletes nothing. A refusal case asserts the whole
# state tree is unchanged, and each guard has a red twin that runs the same
# check against a scratch copy with that guard removed.
#
# Run under bash 5: `.gaia/scripts/bats5.sh .gaia/scripts/tests/state-cleanup.bats`.
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

VERB_FILES="state-cleanup.sh state-reaper-classes.sh state-reaper-lib.sh main-root-lib.sh state-registry-lib.sh branch-name-lib.sh audit-key-lib.sh audit-loop-state-lib.sh"

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  REAL_GIT="$(command -v git)"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIRECTORY/state-reaper-classes.sh"
  MAIN="$BATS_TEST_TMPDIR/main"
  LOCAL="$MAIN/.gaia/local"
  VERB="$MAIN/.gaia/scripts/state-cleanup.sh"
  WRAPPER_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$WRAPPER_BIN"
}

# make_main: a main checkout with one commit, the verb with its libraries and
# the committed registry.
make_main() {
  local file
  "$REAL_GIT" init -q -b trunk "$MAIN"
  "$REAL_GIT" -C "$MAIN" -c user.name=fixture -c user.email=fixture@example.com commit -q --allow-empty -m init
  mkdir -p "$MAIN/.gaia/scripts" "$LOCAL"
  for file in $VERB_FILES; do
    cp "$SCRIPT_DIRECTORY/$file" "$MAIN/.gaia/scripts/$file" || return 1
  done
  cp "$SCRIPT_DIRECTORY/../state-registry.json" "$MAIN/.gaia/state-registry.json" || return 1
}

branch() { "$REAL_GIT" -C "$MAIN" branch "$1"; }

# plant_state <branch>: the four kinds of state a branch owns, named by the
# real key functions; prints nothing.
plant_state() {
  local slug normalized
  slug="$(gaia_key_slug "$1")"
  normalized="$(gaia_branch_normalize "$1")"
  mkdir -p "$LOCAL/audit/light" "$LOCAL/runs/$normalized" "$LOCAL/cache"
  : >"$LOCAL/audit/0123abc.$slug.review.diff"
  : >"$LOCAL/audit/0123abc.$slug.scope.json"
  : >"$LOCAL/audit/light/$slug.reviews.jsonl"
  : >"$LOCAL/runs/$normalized/STATE.md"
  : >"$LOCAL/cache/gh-artifact-pr.$slug.json"
}

# state_exists <branch>: every kind present. state_gone <branch>: none present.
state_paths() {
  local slug normalized
  slug="$(gaia_key_slug "$1")"
  normalized="$(gaia_branch_normalize "$1")"
  printf '%s\n' \
    "audit/0123abc.$slug.review.diff" \
    "audit/0123abc.$slug.scope.json" \
    "audit/light/$slug.reviews.jsonl" \
    "runs/$normalized" \
    "cache/gh-artifact-pr.$slug.json"
}

state_exists() {
  local relative
  while IFS= read -r relative; do
    [ -e "$LOCAL/$relative" ] || { echo "FAIL: $relative is gone"; return 1; }
  done < <(state_paths "$1")
}

state_gone() {
  local relative
  while IFS= read -r relative; do
    [ -e "$LOCAL/$relative" ] && { echo "FAIL: $relative remains"; return 1; }
  done < <(state_paths "$1")
  return 0
}

state_listing() { find "$LOCAL" | sort; }

# git_wrapper <command-word>: a git on PATH that fails the named subcommand
# and passes everything else to the real git.
git_wrapper() {
  cat >"$WRAPPER_BIN/git" <<WRAPPER
#!/usr/bin/env bash
for argument in "\$@"; do
  [ "\$argument" = "$1" ] && exit 1
done
exec "$REAL_GIT" "\$@"
WRAPPER
  chmod +x "$WRAPPER_BIN/git"
}

# mutate <file> <sed args...>: edits one of the fixture's copies in place and
# fails when the edit changed nothing, so a twin cannot go vacuous.
mutate() {
  local target="$MAIN/.gaia/scripts/$1" copy="$BATS_TEST_TMPDIR/mutation.tmp"
  shift
  sed "$@" "$target" >"$copy" || return 1
  if cmp -s "$copy" "$target"; then
    echo "the mutation changed nothing"
    return 1
  fi
  cp "$copy" "$target"
}

# check_refuses <wrapped-command-word|-> <branch>: the verb prints a kept
# state line, exits 0 and leaves the state tree unchanged.
check_refuses() {
  local before after
  [ "$1" = "-" ] || git_wrapper "$1"
  before="$(state_listing)"
  [ "$(printf '%s\n' "$before" | wc -l | tr -d ' ')" -gt 3 ] || { echo "FAIL: the fixture holds no state"; return 1; }
  if [ "$1" = "-" ]; then
    OUTPUT="$(bash "$VERB" --branch "$2" 2>&1)" || { echo "FAIL: exit non-zero: $OUTPUT"; return 1; }
  else
    OUTPUT="$(PATH="$WRAPPER_BIN:$PATH" bash "$VERB" --branch "$2" 2>&1)" || { echo "FAIL: exit non-zero: $OUTPUT"; return 1; }
  fi
  printf '%s\n' "$OUTPUT" | grep -Fq 'kept state' || { echo "FAIL: no kept state line: $OUTPUT"; return 1; }
  after="$(state_listing)"
  [ "$before" = "$after" ] || { echo "FAIL: state changed"; return 1; }
  return 0
}

assert_red() {
  local reason="$1"
  shift
  run "$@"
  [ "$status" -ne 0 ] || { echo "the check stayed green on the mutated copy"; return 1; }
  printf '%s\n' "$output" | grep -Fq -- "$reason" || { printf 'red for another reason: %s\n' "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# Removal

@test "a merged branch loses its audit, run and PR-cache state; an open branch keeps all of it" {
  make_main
  branch fix/b
  plant_state fix/a
  plant_state fix/b
  mkdir -p "$LOCAL/protected/audit-loop/fix"
  : >"$LOCAL/protected/audit-loop/fix/a.json"
  run bash "$VERB" --branch fix/a
  [ "$status" -eq 0 ] || return 1
  state_gone fix/a || return 1
  state_exists fix/b || return 1
  [ -d "$LOCAL/runs/fix" ] || { echo "the shared runs/fix directory was removed"; return 1; }
  [ -e "$LOCAL/protected/audit-loop/fix/a.json" ] || { echo "protected state was removed"; return 1; }
  printf '%s\n' "$output" | grep -Fq 'removed runs/fix/a' || { echo "no removal line: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# Refusals

@test "an empty branch name keeps all state" {
  make_main
  plant_state x
  check_refuses - ""
}

@test "a worktree- name keeps the state its normalized key would name" {
  make_main
  plant_state x
  check_refuses - worktree-x
  state_exists x
}

@test "a name that cannot key a state entry keeps all state" {
  make_main
  plant_state x
  check_refuses - '../x'
}

@test "a branch that still has a local ref keeps its state" {
  make_main
  branch fix/a
  plant_state fix/a
  check_refuses - fix/a
}

@test "a branch checked out in a listed worktree keeps its state" {
  make_main
  "$REAL_GIT" -C "$MAIN" worktree add -q -b fix/a "$BATS_TEST_TMPDIR/tree"
  plant_state fix/a
  check_refuses - fix/a
}

@test "a worktree list that cannot be read keeps all state" {
  make_main
  plant_state fix/a
  check_refuses worktree fix/a
}

@test "a merged branch whose key a live worktree session still holds keeps its run folder" {
  make_main
  "$REAL_GIT" -C "$MAIN" worktree add -q -b 'worktree-fix+a' "$BATS_TEST_TMPDIR/session-tree"
  plant_state fix/a
  run bash "$VERB" --branch fix/a
  [ "$status" -eq 0 ] || return 1
  [ -d "$LOCAL/runs/fix/a" ] || { echo "the live key's run folder was removed: $output"; return 1; }
}

@test "a merged parent branch keeps the run folders of a live branch nested under it" {
  make_main
  branch fix/b
  plant_state fix
  plant_state fix/b
  run bash "$VERB" --branch fix
  [ "$status" -eq 0 ] || return 1
  [ -d "$LOCAL/runs/fix/b" ] || { echo "the nested live run folder was removed: $output"; return 1; }
  [ -d "$LOCAL/runs/fix" ] || { echo "the parent run folder was removed: $output"; return 1; }
}

@test "a ref read that fails keeps the nested run folders and prints a kept state line" {
  make_main
  branch fix/b
  plant_state fix
  plant_state fix/b
  check_refuses for-each-ref fix
  [ -d "$LOCAL/runs/fix/b" ]
}

# ---------------------------------------------------------------------------
# Red twins: the same check against a scratch copy with the guard removed

@test "red twin: without the empty-name and keyable guards the empty name is not refused" {
  make_main
  plant_state x
  mutate state-cleanup.sh -e '/^\[ -n "\$branch_name" \] || keep_state/d' -e '/^_gaia_loop_keyable /d' || return 1
  assert_red "no kept state line" check_refuses - ""
}

@test "red twin: without the worktree- guard the prefixed name removes the state of its key" {
  make_main
  plant_state x
  mutate state-cleanup.sh -e '/^  worktree-\*) keep_state/d' || return 1
  assert_red "FAIL:" check_refuses - worktree-x
}

@test "red twin: without the keyable guard an unkeyable name is not refused" {
  make_main
  plant_state x
  mutate state-cleanup.sh -e '/^_gaia_loop_keyable /d' || return 1
  assert_red "no kept state line" check_refuses - '../x'
}

@test "red twin: without the live-branch guard a branch with a ref is not refused" {
  make_main
  branch fix/a
  plant_state fix/a
  mutate state-cleanup.sh -e 's/^\$branch_name$/NEVER-MATCHES/' || return 1
  assert_red "no kept state line" check_refuses - fix/a
}

@test "red twin: without the read-OK guard an unreadable worktree list is not refused" {
  make_main
  plant_state fix/a
  mutate state-cleanup.sh -e 's/^if \[ -z "\${GAIA_REAPER_BRANCHES_OK-}" \] || \[ -z "\${GAIA_REAPER_TREES_OK-}" \]; then$/if false; then/' || return 1
  assert_red "no kept state line" check_refuses worktree fix/a
}

@test "red twin: without the live-key check in the reaper a live session key loses its run folder" {
  make_main
  "$REAL_GIT" -C "$MAIN" worktree add -q -b 'worktree-fix+a' "$BATS_TEST_TMPDIR/session-tree"
  plant_state fix/a
  mutate state-reaper-classes.sh -e 's/^  if gaia_reaper_path_live "\$key" "\$live_keys"; then$/  if false; then/' || return 1
  run bash "$VERB" --branch fix/a
  [ -d "$LOCAL/runs/fix/a" ] && { echo "the mutation did not remove the run folder"; return 1; }
  true
}

@test "red twin: without the live-key check in the reaper a nested live run folder is removed" {
  make_main
  branch fix/b
  plant_state fix
  plant_state fix/b
  mutate state-reaper-classes.sh -e 's/^  if gaia_reaper_path_live "\$key" "\$live_keys"; then$/  if false; then/' || return 1
  run bash "$VERB" --branch fix
  [ -d "$LOCAL/runs/fix/b" ] && { echo "the mutation did not remove the nested folder"; return 1; }
  true
}
