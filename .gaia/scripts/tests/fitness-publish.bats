#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/fitness-publish.sh: the commit, push and
# draft pull request mechanics behind the /gaia-fitness publish gate. Each test
# builds a bare remote, a working clone and a `gh` shim first on PATH that
# records every call, so the options of the gate can be told apart by what the
# script did, not by what its prose says.
#
# Run under bash 5: `.gaia/scripts/bats5.sh .gaia/scripts/tests/fitness-publish.bats < /dev/null`
# (.claude/rules/bats-assertions.md).

setup() {
  PUBLISH_SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/fitness-publish.sh"
  BASE="$BATS_TEST_TMPDIR/base"
  SHIM_DIR="$BASE/shim"
  SHIM_LOG="$BASE/gh.log"
  mkdir -p "$BASE" "$SHIM_DIR"
  : >"$SHIM_LOG"

  . "$BATS_TEST_DIRNAME/../../tests/helpers/catchup-fixture.sh"
  catchup_init "$BASE/sandbox"
  REMOTE="$CATCHUP_ORIGIN"
  CLONE="$CATCHUP_ROOT"
  git -C "$CLONE" checkout -q -b fitness-branch

  cat >"$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SHIM_LOG"
if [ "$1 $2" = "pr create" ]; then
  [ -n "${SHIM_FAIL:-}" ] && { echo "shim: pr create refused" >&2; exit 1; }
  echo "https://github.com/example/repo/pull/42"
  exit 0
fi
exit 0
SHIM
  chmod +x "$SHIM_DIR/gh"
  export SHIM_LOG
  PATH="$SHIM_DIR:$PATH"

  printf 'chore(fitness): fix things\n' >"$BASE/message.txt"
  printf 'body text\n' >"$BASE/body.txt"
  printf 'changed\n' >"$CLONE/fixed.txt"
}

remote_branch_exists() {
  git -C "$REMOTE" rev-parse --verify -q "refs/heads/$1" >/dev/null
}

reject_pushes() {
  mkdir -p "$REMOTE/hooks"
  printf '#!/bin/sh\nexit 1\n' >"$REMOTE/hooks/pre-receive"
  chmod +x "$REMOTE/hooks/pre-receive"
  # A global core.hooksPath would otherwise shadow the remote's own hooks.
  git -C "$REMOTE" config core.hooksPath "$REMOTE/hooks"
}

run_open() {
  run bash "$PUBLISH_SCRIPT" open --root "$CLONE" --branch fitness-branch \
    --message-file "$BASE/message.txt" --title "chore(fitness): fix things" \
    --body-file "$BASE/body.txt"
}

@test "open makes one commit, one push and one draft pull request, and prints the number" {
  run_open
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
  [ "$(git -C "$CLONE" rev-list --count main..fitness-branch)" -eq 1 ]
  [ "$(git -C "$CLONE" log -1 --format=%s)" = "chore(fitness): fix things" ]
  remote_branch_exists fitness-branch
  [ "$(git -C "$REMOTE" rev-parse fitness-branch)" = "$(git -C "$CLONE" rev-parse HEAD)" ]
  [ "$(grep -c '^pr create' "$SHIM_LOG")" -eq 1 ]
  grep -q -- '--draft' "$SHIM_LOG"
}

@test "open never calls a merge, and the script holds no merge command line" {
  run_open
  [ "$status" -eq 0 ]
  grep -q 'pr merge' "$SHIM_LOG" && return 1
  grep -nE '^[[:space:]]*[^#[:space:]].*gh pr merge' "$PUBLISH_SCRIPT" && return 1
  true
}

@test "open stages untracked files too" {
  printf 'new\n' >"$CLONE/untracked.txt"
  run_open
  [ "$status" -eq 0 ]
  git -C "$CLONE" show --name-only --format= HEAD | grep -q '^untracked.txt$'
}

@test "an in-place commit subcommand is a usage error and commits nothing" {
  run bash "$PUBLISH_SCRIPT" commit --root "$CLONE" --message-file "$BASE/message.txt"
  [ "$status" -eq 2 ]
  [ "$(git -C "$CLONE" rev-list --count main..fitness-branch)" -eq 0 ]
  remote_branch_exists fitness-branch && return 1
  [ ! -s "$SHIM_LOG" ]
}

@test "keeping for review runs nothing: no subcommand leaves the remote and the shim log untouched" {
  run bash "$PUBLISH_SCRIPT"
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
  remote_branch_exists fitness-branch && return 1
  [ "$(git -C "$CLONE" rev-list --count main..fitness-branch)" -eq 0 ]
}

@test "a merge subcommand is a usage error and calls nothing" {
  run bash "$PUBLISH_SCRIPT" merge --pr 1
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
  remote_branch_exists fitness-branch && return 1
  true
}

@test "open without a required option is a usage error and commits nothing" {
  run bash "$PUBLISH_SCRIPT" open --root "$CLONE" --branch fitness-branch --message-file "$BASE/message.txt"
  [ "$status" -eq 2 ]
  [ "$(git -C "$CLONE" rev-list --count main..fitness-branch)" -eq 0 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "open refuses a branch name that looks like an option" {
  run bash "$PUBLISH_SCRIPT" open --root "$CLONE" --branch=--force \
    --message-file "$BASE/message.txt" --title t --body-file "$BASE/body.txt"
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "a rejecting remote fails the open, names the push and never opens a pull request" {
  reject_pushes
  run_open
  [ "$status" -ne 0 ]
  [[ "$output" == *"git push"* ]]
  grep -q '^pr create' "$SHIM_LOG" && return 1
  true
}

@test "a failing pull request creation fails the open and names the command" {
  SHIM_FAIL=1 run_open
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh pr create"* ]]
}

@test "a clean tree fails the open at the commit and pushes nothing" {
  rm "$CLONE/fixed.txt"
  run_open
  [ "$status" -ne 0 ]
  [[ "$output" == *"git commit"* ]]
  remote_branch_exists fitness-branch && return 1
  [ ! -s "$SHIM_LOG" ]
}

@test "a pull request URL with no number fails the open" {
  cat >"$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SHIM_LOG"
echo "not a url"
SHIM
  run_open
  [ "$status" -ne 0 ]
  [[ "$output" == *"pull request number"* ]]
}
