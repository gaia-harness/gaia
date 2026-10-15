#!/usr/bin/env bats
# Tests for `.gaia/scripts/spec/spec-renumber.sh`: the best-effort `.lock`
# re-key (a SPEC renumbered while its liveness lock is live must have the lock
# follow the id, not strand under the old one: a stranded lock would make
# `status <new_id>` read dormant even though the session is still authoring),
# and the notebook side: the folder moves, the catalog row is re-keyed under the
# catalog lock, a taken id is refused and a not-ready notebook is left alone.
#
# Uses helpers/tmp-notebook-repo.sh (already copies spec-renumber.sh and the
# notebook library into the tmp repo). Each test spins up its own tmp git repo
# and tears it down; hermetic, no reliance on the real project notebook.
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# Builds the throwaway fixture repository the suite acts on.
_fixture_repository() {
  "$HELPERS/tmp-notebook-repo.sh" "$@"
}

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  RENUMBER=".gaia/scripts/spec/spec-renumber.sh"
  CACHE=".gaia/local/cache"
  . "$BATS_TEST_DIRNAME/../helpers/files.sh"
}

teardown() {
  # The spawned stand-in "session host" process outlives the test unless
  # killed here; it is never reaped by the script under test.
  if [ -n "${SPAWN_PID:-}" ]; then
    kill "$SPAWN_PID" 2>/dev/null || true
    wait "$SPAWN_PID" 2>/dev/null || true
  fi
  if [ -n "${HOLDER_PID:-}" ]; then
    rm -f "${RELEASE_FILE:-}"
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

_renumber() {
  bash "$REPO/$RENUMBER" "$@"
}

_catalog() {
  printf '%s\n' "$REPO/.notebook/catalog.json"
}

_hash_notebook() {
  local hasher="shasum -a 256"
  command -v shasum >/dev/null 2>&1 || hasher="sha256sum"
  find "$REPO/.notebook" -type f -exec $hasher {} + | LC_ALL=C sort
}

_row() {
  jq -c --arg id "$1" '.items[] | select(.kind == "spec" and .id == $id)' "$(_catalog)"
}

# --- 1: renumber-while-live re-keys the .lock, preserving its live pid ------

@test "1: renumbering a draft with a live-shaped .lock re-keys it and keeps the recorded pid" {
  REPO="$(_fixture_repository --seed-spec-folder SPEC-901 draft)"

  # Stand in for a live session-host: a real, long-lived background process
  # whose pid the lock records, so "is the pid still alive" is genuinely true.
  sleep 300 &
  SPAWN_PID=$!

  jq -n --arg id "SPEC-901" --argjson pid "$SPAWN_PID" \
    '{spec_id: $id, hostname: "test-host", host_pid: $pid,
      host_lstart: "irrelevant-for-this-test", host_nonce: "test-nonce",
      acquired_at: "2026-01-01T00:00:00Z"}' \
    > "$REPO/$CACHE/spec-session-SPEC-901.lock"

  run _renumber "$REPO" SPEC-901 SPEC-902
  [ "$status" -eq 0 ]

  [ -f "$REPO/$CACHE/spec-session-SPEC-902.lock" ]
  [ ! -e "$REPO/$CACHE/spec-session-SPEC-901.lock" ]

  # The pid rides along unchanged, so a `status SPEC-902` kill-0 check would
  # still find it alive: the live session's lock followed the id rather than
  # stranding under the old one.
  [ "$(jq -r '.host_pid' "$REPO/$CACHE/spec-session-SPEC-902.lock")" = "$SPAWN_PID" ]
  [ "$(jq -r '.spec_id' "$REPO/$CACHE/spec-session-SPEC-902.lock")" = "SPEC-902" ]
}

# --- 2: a missing lock is a normal no-op ------------------------------------

@test "2: renumbering a draft with no .lock file is a no-op for the lock re-key" {
  REPO="$(_fixture_repository --seed-spec-folder SPEC-903 draft)"

  run _renumber "$REPO" SPEC-903 SPEC-904
  [ "$status" -eq 0 ]

  [ ! -e "$REPO/$CACHE/spec-session-SPEC-903.lock" ]
  [ ! -e "$REPO/$CACHE/spec-session-SPEC-904.lock" ]
}

# --- 3b: the rename hint rewrites a padded branch number --------------------

@test "3b: the rename hint rewrites a padded branch number" {
  REPO="$(_fixture_repository --seed-spec-folder SPEC-011 draft)"
  git -C "$REPO" checkout -q -b "plan/spec-011-cards"

  run _renumber "$REPO" SPEC-011 SPEC-012
  [ "$status" -eq 0 ]
  grep -qF "branch -m 'plan/spec-012-cards'" <<<"$output"
}

# --- 8: renumber a foldered SPEC ---------------------------------------------

@test "8a: renumber renames the folder; SPEC.md keeps its name; siblings ride along" {
  REPO="$(_fixture_repository --seed-spec-folder SPEC-002 draft)"
  echo "report body" > "$REPO/.notebook/specs/SPEC-002/REPORT.md"

  run _renumber "$REPO" SPEC-002 SPEC-005
  [ "$status" -eq 0 ]

  [ ! -e "$REPO/.notebook/specs/SPEC-002" ]
  [ -f "$REPO/.notebook/specs/SPEC-005/SPEC.md" ]
  [ -f "$REPO/.notebook/specs/SPEC-005/REPORT.md" ]
  [ "$(cat "$REPO/.notebook/specs/SPEC-005/REPORT.md")" = "report body" ]
  # Inner SPEC.md frontmatter id rewritten.
  grep -q '^spec_id: SPEC-005$' "$REPO/.notebook/specs/SPEC-005/SPEC.md"
  # Nothing was created in the retired locations.
  [ ! -e "$REPO/.gaia/local/specs" ]
}

@test "8b: renumber collision guard fires when the target folder exists" {
  REPO="$(_fixture_repository --seed-spec-folder SPEC-002 draft --seed-spec-folder SPEC-005 draft)"

  run _renumber "$REPO" SPEC-002 SPEC-005
  [ "$status" -eq 4 ]
  # Source folder untouched on a refused renumber.
  [ -f "$REPO/.notebook/specs/SPEC-002/SPEC.md" ]
}

# --- 9: the catalog row is re-keyed ------------------------------------------

@test "9a: the row id and path change, renamed_from is stamped and other fields are kept" {
  REPO="$(_fixture_repository --seed-row '{"kind":"spec","id":"SPEC-002","path":"specs/SPEC-002","status":"draft","subject":"keep me","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z","reservation":"provisional","source":"allocated"}')"
  mkdir -p "$REPO/.notebook/specs/SPEC-002"
  printf -- '---\nspec_id: SPEC-002\nstatus: draft\n---\n' > "$REPO/.notebook/specs/SPEC-002/SPEC.md"

  run _renumber "$REPO" SPEC-002 SPEC-007
  [ "$status" -eq 0 ]

  [ -z "$(_row SPEC-002)" ]
  [ "$(_row SPEC-007 | jq -r '.path')" = "specs/SPEC-007" ]
  [ "$(_row SPEC-007 | jq -r '.renamed_from')" = "SPEC-002" ]
  [ "$(_row SPEC-007 | jq -r '.subject')" = "keep me" ]
  [ "$(_row SPEC-007 | jq -r '.reservation')" = "provisional" ]
  [ "$(_row SPEC-007 | jq -r '.created_at')" = "2026-01-01T00:00:00Z" ]
  [ "$(jq '[.items[] | select(.kind == "spec")] | length' "$(_catalog)")" -eq 1 ]
}

@test "9b: renumbering onto an id whose row already exists is refused and changes nothing" {
  REPO="$(_fixture_repository --seed-spec-folder SPEC-002 draft --seed-spec SPEC-005 ready)"
  before_catalog="$(snapshot_file "$(_catalog)")"
  before_listing="$(find "$REPO/.notebook" -type f | LC_ALL=C sort)"

  run _renumber "$REPO" SPEC-002 SPEC-005
  [ "$status" -eq 4 ]
  grep -qF "SPEC-005" <<<"$output"

  after_catalog="$(snapshot_file "$(_catalog)")"
  assert_files_identical "$before_catalog" "$after_catalog"
  [ "$(find "$REPO/.notebook" -type f | LC_ALL=C sort)" = "$before_listing" ]
  [ -f "$REPO/.notebook/specs/SPEC-002/SPEC.md" ]
  grep -q '^spec_id: SPEC-002$' "$REPO/.notebook/specs/SPEC-002/SPEC.md"
}

@test "9c: a catalog write that fails after the folder moved puts the folder back" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "a read-only folder does not stop root"
  fi
  REPO="$(_fixture_repository --seed-spec-folder SPEC-002 draft)"
  # A read-only notebook folder lets every read and the lock succeed while the
  # catalog temp file cannot be created, so the row re-key is what fails.
  chmod a-w "$REPO/.notebook"

  run _renumber "$REPO" SPEC-002 SPEC-006
  chmod u+w "$REPO/.notebook"
  [ "$status" -ne 0 ]
  [ -f "$REPO/.notebook/specs/SPEC-002/SPEC.md" ]
  grep -q '^spec_id: SPEC-002$' "$REPO/.notebook/specs/SPEC-002/SPEC.md"
  [ ! -e "$REPO/.notebook/specs/SPEC-006" ]
  [ -n "$(_row SPEC-002)" ]
}

# --- 10: the renumber runs under the catalog lock ----------------------------

# Hold the catalog write lock until RELEASE_FILE disappears; returns once held.
_hold_catalog_lock() {
  RELEASE_FILE="$BATS_TEST_TMPDIR/release"
  local held_file="$BATS_TEST_TMPDIR/held"
  : > "$RELEASE_FILE"
  rm -f "$held_file"
  GAIA_NOTEBOOK_TREE="$REPO" bash -c '
    . "$1/.gaia/scripts/notebook/notebook-lib.sh"
    hold() { : > "$2"; while [ -e "$3" ]; do sleep 0.1; done; }
    gaia_notebook_with_catalog_lock hold _ "$2" "$3"
  ' _ "$REPO" "$held_file" "$RELEASE_FILE" &
  HOLDER_PID=$!
  local waited=0
  while [ ! -e "$held_file" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$held_file" ]
}

@test "10a: while another writer holds the catalog lock the renumber waits, then completes" {
  REPO="$(_fixture_repository --seed-spec-folder SPEC-002 draft)"
  _hold_catalog_lock

  _renumber "$REPO" SPEC-002 SPEC-008 >"$BATS_TEST_TMPDIR/renumber.out" 2>&1 &
  renumber_pid=$!
  sleep 1
  # Still waiting on the lock: nothing moved and the row is unchanged.
  [ -f "$REPO/.notebook/specs/SPEC-002/SPEC.md" ]
  [ ! -e "$REPO/.notebook/specs/SPEC-008" ]
  [ -n "$(_row SPEC-002)" ]

  rm -f "$RELEASE_FILE"
  wait "$renumber_pid"
  wait "$HOLDER_PID" || true
  HOLDER_PID=""

  [ ! -e "$REPO/.notebook/specs/SPEC-002" ]
  [ -f "$REPO/.notebook/specs/SPEC-008/SPEC.md" ]
  [ -n "$(_row SPEC-008)" ]
}

@test "10b: registers racing a renumber lose neither write" {
  REPO="$(_fixture_repository --seed-spec-folder SPEC-002 draft)"
  notebook_library="$REPO/.gaia/scripts/notebook/notebook-lib.sh"

  _renumber "$REPO" SPEC-002 SPEC-009 >"$BATS_TEST_TMPDIR/renumber.out" 2>&1 &
  for index in 1 2 3 4 5 6; do
    GAIA_NOTEBOOK_TREE="$REPO" bash "$notebook_library" register research "racer-$index" active >/dev/null 2>&1 &
  done
  wait

  [ -n "$(_row SPEC-009)" ]
  [ -z "$(_row SPEC-002)" ]
  [ "$(jq '[.items[] | select(.kind == "research")] | length' "$(_catalog)")" -eq 6 ]
}

# --- 11: not ready -----------------------------------------------------------

@test "11: a not-ready notebook is left alone: exit 3, the move line on stderr, no folder and no row renamed" {
  REPO="$(_fixture_repository --legacy --seed-spec-folder SPEC-002 draft)"
  before_catalog="$(snapshot_file "$(_catalog)")"
  before_listing="$(find "$REPO/.notebook" "$REPO/.gaia/local/specs" -type f | LC_ALL=C sort)"
  before_hashes="$(_hash_notebook)"

  run --separate-stderr _renumber "$REPO" SPEC-002 SPEC-006
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"bash .gaia/scripts/notebook/move.sh run"* ]]

  after_catalog="$(snapshot_file "$(_catalog)")"
  assert_files_identical "$before_catalog" "$after_catalog"
  [ "$(find "$REPO/.notebook" "$REPO/.gaia/local/specs" -type f | LC_ALL=C sort)" = "$before_listing" ]
  [ "$(_hash_notebook)" = "$before_hashes" ]
  [ -f "$REPO/.notebook/specs/SPEC-002/SPEC.md" ]
  [ ! -e "$REPO/.notebook/specs/SPEC-006" ]
}

@test "12: run from a linked worktree, the renumber lands in main's notebook" {
  built="$(_fixture_repository --seed-spec-folder SPEC-002 draft --worktree x)"
  REPO="$(printf '%s\n' "$built" | sed -n 1p)"
  WORKTREE="$(printf '%s\n' "$built" | sed -n 2p)"

  run bash "$REPO/$RENUMBER" "$WORKTREE" SPEC-002 SPEC-004
  [ "$status" -eq 0 ]

  [ -f "$REPO/.notebook/specs/SPEC-004/SPEC.md" ]
  [ ! -e "$REPO/.notebook/specs/SPEC-002" ]
  [ -n "$(_row SPEC-004)" ]
  [ ! -e "$WORKTREE/.gaia/local/specs" ]
  rm -rf "$WORKTREE"
}
