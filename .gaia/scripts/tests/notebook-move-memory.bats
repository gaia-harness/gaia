#!/usr/bin/env bats
# Tests for notebook/move.sh memory-report and memory-repoint: the auto-memory
# files that name an old specs, plans or research location. Neither verb runs
# the move, and the repoint rewrites exactly the files the report lists.
#
# Every invocation puts a recording rm shim first on PATH: nothing here may
# delete, and teardown fails any test during which the shim was called.

bats_require_minimum_version 1.5.0

_fixture_repository() {
  "$BATS_TEST_DIRNAME/../../tests/lib/helpers/tmp-notebook-repo.sh" "$@"
}

setup() {
  SHIM_DIRECTORY="$BATS_TEST_TMPDIR/shims"
  RM_CALLS="$BATS_TEST_TMPDIR/rm-calls"
  mkdir -p "$SHIM_DIRECTORY"
  printf '#!/bin/sh\necho "$@" >> "%s"\nexit 0\n' "$RM_CALLS" > "$SHIM_DIRECTORY/rm"
  chmod +x "$SHIM_DIRECTORY/rm"
  REPO="$(_fixture_repository --no-catalog)"
  MEMORY="$BATS_TEST_TMPDIR/memory"
  mkdir -p "$MEMORY"
  export GAIA_NOTEBOOK_MEMORY_DIR="$MEMORY"
}

teardown() {
  local calls=""
  [ -f "$RM_CALLS" ] && calls="$(cat "$RM_CALLS")"
  [ -n "$REPO" ] && command rm -rf "$REPO"
  if [ -n "$calls" ]; then
    echo "rm was invoked during the test: $calls" >&2
    return 1
  fi
}

_move() {
  env PATH="$SHIM_DIRECTORY:$PATH" GAIA_NOTEBOOK_TREE="$REPO" \
    bash "$REPO/.gaia/scripts/notebook/move.sh" "$@"
}

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

_plant_memory() {
  printf 'specs at .gaia/local/specs/ and plans at .gaia/local/plans/ and note .gaia/local/research/topic-2026/README.md and near miss .gaia/local/specs-old/x\n' \
    > "$MEMORY/old-paths.md"
  printf 'cache lives in .gaia/local/cache/x\n' > "$MEMORY/unrelated.md"
}

@test "memory-report lists only files naming an old prefix and changes nothing" {
  _plant_memory
  local first_before second_before
  first_before="$(_sha256 "$MEMORY/old-paths.md")"
  second_before="$(_sha256 "$MEMORY/unrelated.md")"
  run _move memory-report
  [ "$status" -eq 0 ]
  [ "$output" = "$MEMORY/old-paths.md" ]
  [ "$(_sha256 "$MEMORY/old-paths.md")" = "$first_before" ]
  [ "$(_sha256 "$MEMORY/unrelated.md")" = "$second_before" ]
}

@test "memory-report does not list a near miss or a file in a subfolder or a symlink" {
  printf 'only .gaia/local/specs-old/x\n' > "$MEMORY/near-miss.md"
  mkdir -p "$MEMORY/nested"
  printf '.gaia/local/specs/\n' > "$MEMORY/nested/deep.md"
  printf '.gaia/local/specs/\n' > "$BATS_TEST_TMPDIR/target.md"
  ln -s "$BATS_TEST_TMPDIR/target.md" "$MEMORY/linked.md"
  run _move memory-report
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "memory-report on an absent memory folder prints nothing" {
  export GAIA_NOTEBOOK_MEMORY_DIR="$BATS_TEST_TMPDIR/not-there"
  run _move memory-report
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "memory-repoint rewrites exactly the three prefixes in exactly the reported files" {
  _plant_memory
  local second_before
  second_before="$(_sha256 "$MEMORY/unrelated.md")"
  chmod 640 "$MEMORY/old-paths.md"
  run _move memory-repoint
  [ "$status" -eq 0 ]
  [ "$(cat "$MEMORY/old-paths.md")" = 'specs at .notebook/specs/ and plans at .notebook/plans/ and note .notebook/research/topic-2026/README.md and near miss .gaia/local/specs-old/x' ]
  [ "$(_sha256 "$MEMORY/unrelated.md")" = "$second_before" ]
  [ "$(stat -c %a "$MEMORY/old-paths.md" 2>/dev/null || stat -f %Lp "$MEMORY/old-paths.md")" = 640 ]
  # The report is empty once the files are repointed.
  run _move memory-report
  [ -z "$output" ]
}

@test "memory-repoint keeps a file without a trailing newline as it was" {
  printf '.gaia/local/plans/x' > "$MEMORY/no-newline.md"
  run _move memory-repoint
  [ "$status" -eq 0 ]
  [ "$(od -c "$MEMORY/no-newline.md" | tail -2 | head -1 | tr -d ' ')" != "" ]
  [ "$(cat "$MEMORY/no-newline.md")" = '.notebook/plans/x' ]
  [ "$(wc -c < "$MEMORY/no-newline.md" | tr -d ' ')" -eq 17 ]
}

@test "memory-repoint refuses a symlink that names an old prefix and changes nothing" {
  _plant_memory
  printf 'target names .gaia/local/specs/ here\n' > "$BATS_TEST_TMPDIR/target.md"
  ln -s "$BATS_TEST_TMPDIR/target.md" "$MEMORY/linked.md"
  local target_before regular_before
  target_before="$(_sha256 "$BATS_TEST_TMPDIR/target.md")"
  regular_before="$(_sha256 "$MEMORY/old-paths.md")"
  run _move memory-repoint
  [ "$status" -eq 9 ]
  [[ "$output" == *"linked.md is a symlink"* ]]
  [ "$(_sha256 "$BATS_TEST_TMPDIR/target.md")" = "$target_before" ]
  [ "$(_sha256 "$MEMORY/old-paths.md")" = "$regular_before" ]
  [ -L "$MEMORY/linked.md" ]
}

@test "memory-report and memory-repoint do not run the move" {
  _plant_memory
  mkdir -p "$REPO/.gaia/local/specs/SPEC-001"
  printf '{"version":1,"specs":[]}' > "$REPO/.gaia/local/specs/ledger.json"
  run _move memory-report
  [ "$status" -eq 0 ]
  run _move memory-repoint
  [ "$status" -eq 0 ]
  [ -d "$REPO/.gaia/local/specs/SPEC-001" ]
  [ -f "$REPO/.gaia/local/specs/ledger.json" ]
  [ ! -e "$REPO/.notebook/catalog.json" ]
}
