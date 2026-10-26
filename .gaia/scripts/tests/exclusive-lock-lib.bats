#!/usr/bin/env bats
#
# Suite for .gaia/scripts/exclusive-lock-lib.sh: a lock directory taken so that
# exactly one contender owns it even when `mkdir` reports success for a
# directory that already exists.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/exclusive-lock-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/exclusive-lock-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/non-exclusive-mkdir.sh"
  LOCK="$BATS_TEST_TMPDIR/state/x.lock"
  mkdir -p "${LOCK%/*}"
}

@test "take: a second take while the lock is held is refused, with a non-exclusive mkdir first on PATH" {
  PATH="$(non_exclusive_mkdir_path)"
  gaia_exclusive_lock_take "$LOCK"
  run gaia_exclusive_lock_take "$LOCK"
  [ "$status" -eq 1 ]
  [ -d "$LOCK" ]
}

@test "take: concurrent writers through the lock all land, with a non-exclusive mkdir first on PATH" {
  local counter="$BATS_TEST_TMPDIR/counter" writer_count=6
  PATH="$(non_exclusive_mkdir_path)"
  printf '0\n' >"$counter"
  writer() {
    local deadline=$(($(date +%s) + 20)) value
    until gaia_exclusive_lock_take "$LOCK"; do
      [ "$(date +%s)" -lt "$deadline" ] || return 1
      sleep 0.05
    done
    value="$(cat "$counter")"
    sleep 0.2
    printf '%s\n' $((value + 1)) >"$counter"
    gaia_exclusive_lock_release "$LOCK"
  }
  for _ in $(seq 1 "$writer_count"); do writer & done
  wait
  [ "$(cat "$counter")" -eq "$writer_count" ]
  [ ! -e "$LOCK" ]
}

@test "take: a bare directory at the lock path reads as held" {
  mkdir "$LOCK"
  run gaia_exclusive_lock_take "$LOCK"
  [ "$status" -eq 1 ]
  [ -d "$LOCK" ]
  [ -e "$LOCK/owner" ] && return 1
  true
}

@test "take: the owner file records the taking process" {
  gaia_exclusive_lock_take "$LOCK"
  [ "$(cat "$LOCK/owner")" = "$$" ]
}

@test "release: frees the lock for the next take, and is rc 0 on an absent lock" {
  gaia_exclusive_lock_take "$LOCK"
  gaia_exclusive_lock_release "$LOCK"
  [ ! -e "$LOCK" ]
  run gaia_exclusive_lock_release "$LOCK"
  [ "$status" -eq 0 ]
  gaia_exclusive_lock_take "$LOCK"
}

@test "take: an empty path is refused" {
  run gaia_exclusive_lock_take ""
  [ "$status" -eq 1 ]
}

@test "sourcing the lib with PATH empty still succeeds" {
  run env PATH= /bin/bash -c ". '$REPO_ROOT/.gaia/scripts/exclusive-lock-lib.sh'; echo ok"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}
