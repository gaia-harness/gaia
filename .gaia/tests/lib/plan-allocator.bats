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

@test "a fresh run registers a ready PLAN-001 row, and the second call mints PLAN-002 with the exact row shape" {
  REPO="$(_fixture_repository)"
  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-001" ]
  [ "$(_plan_rows | jq -r 'length')" -eq 1 ]
  [ "$(_plan_rows | jq -r '.[0].id')" = "PLAN-001" ]
  [ "$(_plan_rows | jq -r '.[0].status')" = "ready" ]
  [ "$(_plan_rows | jq -r '.[0].path')" = "plans/PLAN-001" ]

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

@test "plan-allocator mints one past the highest plan number across catalog rows and on-disk plan folders, ignoring spec rows, spec folders and archived/" {
  local template row seed expected
  template="$(_fixture_repository)"
  for row in \
    "live-folder|PLAN-051" \
    "reaped-row-and-rowless-folder|PLAN-008" \
    "reaped-row-alone|PLAN-005" \
    "spec-row-and-folder|PLAN-001" \
    "archived-folder|PLAN-001" \
    "four-digit|PLAN-1000" \
    "leading-zero|PLAN-019"; do
    seed=${row%%|*}; expected=${row#*|}
    case "$seed" in
      reaped-row-and-rowless-folder)
        REPO="$(_fixture_repository \
          --seed-row '{"kind":"plan","id":"PLAN-004","path":"plans/PLAN-004","status":"merged","subject":"old","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z","reap":{"at":"2026-02-01T00:00:00Z","by":"plan-archive-merged"}}')"
        mkdir -p "$REPO/.notebook/plans/PLAN-007"
        ;;
      reaped-row-alone)
        REPO="$(_fixture_repository \
          --seed-row '{"kind":"plan","id":"PLAN-004","path":"plans/PLAN-004","status":"merged","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z","reap":{"at":null,"by":"pre-catalog"}}')"
        ;;
      spec-row-and-folder)
        REPO="$(_fixture_repository --seed-spec-folder SPEC-009 ready)"
        ;;
      *)
        REPO="$BATS_TEST_TMPDIR/$seed"
        cp -R "$template" "$REPO"
        case "$seed" in
          live-folder) mkdir -p "$REPO/.notebook/plans/PLAN-050" ;;
          archived-folder) mkdir -p "$REPO/.notebook/plans/archived/PLAN-050" ;;
          four-digit) mkdir -p "$REPO/.notebook/plans/PLAN-999" ;;
          leading-zero) mkdir -p "$REPO/.notebook/plans/PLAN-018" ;;
        esac
        ;;
    esac
    run _run_allocator next "$REPO"
    [ "$status" -eq 0 ] || { echo "row $row: status $status"; return 1; }
    [ "$output" = "$expected" ] || { echo "row $row: got '$output'"; return 1; }
    rm -rf "$REPO"
  done
  rm -rf "$template"
  REPO=""
}

@test "plan-allocator normalizes a subject: multiline collapses to one line, an over-bound one is a word-safe bounded prefix with an ellipsis, an empty or absent one falls back to the id" {
  local long stored bounded_prefix single_long single_stored
  REPO="$(_fixture_repository)"
  run _run_allocator next "$REPO" "$(printf 'first line\nsecond line')"
  [ "$status" -eq 0 ]
  [ "$(_plan_rows | jq -r '.[0].subject')" = "first line second line" ]

  long="$(printf 'alphabet%.0s ' $(seq 1 20))"
  run _run_allocator next "$REPO" "$long"
  [ "$status" -eq 0 ]
  stored="$(_plan_rows | jq -r '.[1].subject')"

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
  single_stored="$(_plan_rows | jq -r '.[2].subject')"
  [ "$single_stored" = "$(printf 'a%.0s' $(seq 1 120))..." ]

  run _run_allocator next "$REPO"
  [ "$status" -eq 0 ]
  [ "$(_plan_rows | jq -r '.[3].subject')" = "PLAN-004" ]
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
