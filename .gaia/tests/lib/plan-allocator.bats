#!/usr/bin/env bats
# Tests for plan-allocator.sh: allocates PLAN-NNN ids for spec-less one-off
# plans and registers one catalog row per plan. Local-only (no git
# requirement beyond resolving main, no remote reservation, no network); the
# union of catalog plan rows + on-disk plan folders is the sole collision
# authority. Modeled on the invoked-script idiom in spec-ledger-status.bats:
# plain run/$status/$output, no bats-support/assert libs, per-test temp repo
# via helpers/tmp-notebook-repo.sh.

bats_require_minimum_version 1.5.0

# Builds the throwaway fixture repository the suite acts on.
_fixture_repository() {
  "$HELPERS/tmp-notebook-repo.sh" "$@"
}

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  . "$BATS_TEST_DIRNAME/../helpers/files.sh"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
  if [ -n "${LINKED:-}" ]; then
    rm -rf "$LINKED"
  fi
}

_run_allocator() {
  bash "$REPO/.gaia/scripts/spec/plan-allocator.sh" "$@"
}

# The catalog's plan rows, read straight from the fixture (tests may open it).
_plan_rows() {
  jq -c '[.items[] | select(.kind == "plan")]' "$REPO/.notebook/catalog.json"
}

# Every path under the fixture except git's own store, plus the catalog bytes.
_snapshot() {
  find "$REPO" -path "$REPO/.git" -prune -o -print | LC_ALL=C sort
  if [ -f "$REPO/.notebook/catalog.json" ]; then cksum < "$REPO/.notebook/catalog.json"; fi
}

@test "1: fresh run registers a ready row + returns PLAN-001" {
  REPO="$(_fixture_repository)"
  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-001" ]
  [ "$(_plan_rows | jq -r 'length')" -eq 1 ]
  [ "$(_plan_rows | jq -r '.[0].id')" = "PLAN-001" ]
  [ "$(_plan_rows | jq -r '.[0].status')" = "ready" ]
  [ "$(_plan_rows | jq -r '.[0].path')" = "plans/PLAN-001" ]
}

@test "2: second call returns PLAN-002 with the exact row shape" {
  REPO="$(_fixture_repository)"
  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  run _run_allocator next "$REPO" "my subject"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-002" ]

  [ "$(_plan_rows | jq -r '.[1].id')" = "PLAN-002" ]
  [ "$(_plan_rows | jq -r '.[1].source')" = "allocated" ]
  [ "$(_plan_rows | jq -r '.[1].subject')" = "my subject" ]
  # status (lifecycle) is the new-row canonical "ready"; source (provenance)
  # is unrelated and still reads "allocated". Distinct fields.
  [ "$(_plan_rows | jq -r '.[1].status')" = "ready" ]
  [ "$(_plan_rows | jq -c '.[1] | keys')" = '["created_at","id","kind","path","source","status","status_changed_at","subject"]' ]
  [ "$(_plan_rows | jq -r '.[1].created_at == .[1].status_changed_at')" = "true" ]
  [ "$(_plan_rows | jq -r '.[1].created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")')" = "true" ]

  # 2-space indent, trailing newline (jq's default output).
  grep -qF '  "version"' "$REPO/.notebook/catalog.json"
  [ "$(tail -c1 "$REPO/.notebook/catalog.json" | wc -l)" -eq 1 ]
}

@test "3a: no-terminator multiline subject collapses to one line" {
  REPO="$(_fixture_repository)"
  run _run_allocator next "$REPO" "$(printf 'first line\nsecond line')"
  [ "$status" -eq 0 ]
  [ "$(_plan_rows | jq -r '.[0].subject')" = "first line second line" ]
}

@test "3b: an over-bound multi-word subject is stored as a word-safe bounded prefix + ..." {
  REPO="$(_fixture_repository)"
  long="$(printf 'alphabet%.0s ' $(seq 1 20))"
  run _run_allocator next "$REPO" "$long"
  [ "$status" -eq 0 ]
  stored="$(_plan_rows | jq -r '.[0].subject')"

  case "$stored" in
    *...) ;;
    *) return 1 ;;
  esac

  bounded_prefix="${stored%...}"
  [ "${#bounded_prefix}" -le 120 ]
  [ "${bounded_prefix: -1}" != " " ]

  # word-safe: the bounded prefix ends on a complete "alphabet" token, never
  # a mid-word fragment (e.g. "...alp").
  case "$bounded_prefix" in
    *alphabet) ;;
    *) return 1 ;;
  esac

  # single-token (no interior space) over-bound subject hard-cuts to exactly
  # 120 chars + "...".
  single_long="$(printf 'a%.0s' $(seq 1 150))"
  run _run_allocator next "$REPO" "$single_long"
  [ "$status" -eq 0 ]
  single_stored="$(_plan_rows | jq -r '.[1].subject')"
  [ "$single_stored" = "$(printf 'a%.0s' $(seq 1 120))..." ]
}

@test "3c: empty/absent subject falls back to the allocated id" {
  REPO="$(_fixture_repository)"
  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  [ "$(_plan_rows | jq -r '.[0].subject')" = "PLAN-001" ]
}

@test "4a: a live on-disk PLAN-050 folder is consumed; next allocates PLAN-051" {
  REPO="$(_fixture_repository)"
  mkdir -p "$REPO/.notebook/plans/PLAN-050"
  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-051" ]
}

@test "4b: a reaped row with no folder (PLAN-004) and a row-less folder (PLAN-007) -> PLAN-008" {
  REPO="$(_fixture_repository \
    --seed-row '{"kind":"plan","id":"PLAN-004","path":"plans/PLAN-004","status":"merged","subject":"old","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z","reap":{"at":"2026-02-01T00:00:00Z","by":"plan-archive-merged"}}')"
  mkdir -p "$REPO/.notebook/plans/PLAN-007"
  [ ! -e "$REPO/.notebook/plans/PLAN-004" ]
  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-008" ]
}

@test "4c: a reaped row alone (no folder) still consumes its number" {
  REPO="$(_fixture_repository \
    --seed-row '{"kind":"plan","id":"PLAN-004","path":"plans/PLAN-004","status":"merged","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z","reap":{"at":null,"by":"pre-catalog"}}')"
  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-005" ]
}

@test "4d: a spec row and a spec folder never raise the plan number" {
  REPO="$(_fixture_repository --seed-spec-folder SPEC-009 ready)"
  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-001" ]
}

@test "4e: an archived/ folder is not a plan folder and is not scanned" {
  REPO="$(_fixture_repository)"
  mkdir -p "$REPO/.notebook/plans/archived/PLAN-050"
  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-001" ]
}

@test "5a: PLAN-999 folder expands to 4 digits with no leading zero" {
  REPO="$(_fixture_repository)"
  mkdir -p "$REPO/.notebook/plans/PLAN-999"
  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-1000" ]
}

@test "5b: a leading-zero legacy PLAN-018 folder counts as 18 (base-10, not octal)" {
  REPO="$(_fixture_repository)"
  mkdir -p "$REPO/.notebook/plans/PLAN-018"
  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-019" ]
}

@test "6: concurrent next calls (forced mkdir fallback) yield two distinct ids" {
  REPO="$(_fixture_repository)"
  rm -f "$REPO"/out.* "$REPO/start.flag"

  for i in 1 2; do
    bash -c '
      repo="$1"; job_index="$2"
      until [ -f "$repo/start.flag" ]; do :; done
      GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 bash "$repo/.gaia/scripts/spec/plan-allocator.sh" next "$repo" > "$repo/out.$job_index" 2>/dev/null
    ' _ "$REPO" "$i" &
  done
  touch "$REPO/start.flag"
  wait

  first_allocated_id="$(cat "$REPO/out.1")"
  second_allocated_id="$(cat "$REPO/out.2")"
  [ "$first_allocated_id" != "$second_allocated_id" ]
  ids="$(printf '%s\n%s\n' "$first_allocated_id" "$second_allocated_id" | sort)"
  [ "$ids" = "$(printf 'PLAN-001\nPLAN-002\n')" ]
  [ "$(_plan_rows | jq -r 'length')" -eq 2 ]
}

@test "7: called from a linked worktree, the row lands in main's catalog" {
  fixture="$(_fixture_repository --worktree b)"
  REPO="$(printf '%s\n' "$fixture" | sed -n 1p)"
  LINKED="$(printf '%s\n' "$fixture" | sed -n 2p)"
  run bash "$REPO/.gaia/scripts/spec/plan-allocator.sh" next "$LINKED"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-001" ]
  [ "$(_plan_rows | jq -r '.[0].id')" = "PLAN-001" ]
  [ "$(_plan_rows | jq -r '.[0].status')" = "ready" ]
  # The worktree's notebook stays the link to main's, never a folder of its own.
  [ -L "$LINKED/.notebook" ]
}

@test "8: a legacy (not-yet-moved) repo exits 3 with the move command and mints nothing" {
  REPO="$(_fixture_repository --legacy)"
  before="$(_snapshot)"
  run --separate-stderr _run_allocator next "$REPO"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  case "$stderr" in
    *"bash .gaia/scripts/notebook/move.sh run"*) ;;
    *) return 1 ;;
  esac
  [ "$(_snapshot)" = "$before" ]
}

@test "9: an unknown mode and a missing operand are usage errors (exit 2)" {
  REPO="$(_fixture_repository)"
  run _run_allocator
  [ "$status" -eq 2 ]
  run _run_allocator bogus "$REPO"
  [ "$status" -eq 2 ]
}

@test "10: run from the real repo root, the allocation lands in the operand's fixture only" {
  REPO="$(_fixture_repository)"
  real_root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  real_before="$(directory_listing_checksum "$real_root/.notebook")"
  run bash -c 'cd "$1" && bash "$2/.gaia/scripts/spec/plan-allocator.sh" next "$2"' _ "$real_root" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-001" ]
  [ "$(_plan_rows | jq -r 'length')" -eq 1 ]
  real_after="$(directory_listing_checksum "$real_root/.notebook")"
  [ "$real_after" = "$real_before" ]
}

@test "11: a non-lock library failure (.notebook not gitignored) exits 4, not the raw library status" {
  REPO="$(_fixture_repository)"
  printf '.gaia/local\n' > "$REPO/.gitignore"
  run --separate-stderr _run_allocator next "$REPO"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  case "$stderr" in
    *"catalog write failed"*) ;;
    *) return 1 ;;
  esac
}
