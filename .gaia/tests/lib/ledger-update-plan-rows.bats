#!/usr/bin/env bats
# Tests for `.gaia/scripts/spec/ledger-update.sh`: the single guarded status
# chokepoint over the notebook catalog rows of both kinds, after the initial
# allocation. Covers the plan-row stamps, cross-kind routing, the readiness and
# corrupt-catalog refusals, the fail-closed library probes and lock scope.
#
# Each case runs against a tmp repo from helpers/tmp-notebook-repo.sh, so the
# real catalog is never touched.

setup_file() {
  local this_directory
  this_directory="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  TEMPLATE="$("$this_directory/helpers/tmp-notebook-repo.sh" \
    --seed-row '{"kind":"plan","id":"PLAN-001","path":"plans/PLAN-001","status":"ready","subject":"x","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z","source":"allocated"}' \
    --seed-row '{"kind":"spec","id":"SPEC-001","path":"specs/SPEC-001","status":"draft","subject":"y","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z","reservation":"provisional","intent":"keep me","custom_field":{"nested":true}}')"
  export TEMPLATE
}

teardown_file() {
  rm -rf "${TEMPLATE:-}"
}

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  HELPERS="$THIS_DIRECTORY/helpers"
  SANDBOX="$BATS_TEST_TMPDIR/repo"
  CATALOG="$SANDBOX/.notebook/catalog.json"
  reset_sandbox
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    rm -rf "$SANDBOX" "${SANDBOX}-wt" "${SANDBOX}-other"
  fi
}

# reset_sandbox: a fresh copy of the seeded notebook repo built once per file.
reset_sandbox() {
  rm -rf "$SANDBOX"
  cp -R "$TEMPLATE" "$SANDBOX"
}

_update() {
  bash "$SANDBOX/.gaia/scripts/spec/ledger-update.sh" "$SANDBOX" "$@"
}

_row_field() {
  local kind="$1" id="$2" field="$3"
  jq -r --arg kind "$kind" --arg id "$id" --arg field_name "$field" \
    '.items[] | select(.kind == $kind and .id == $id) | .[$field_name] // "null"' \
    "$CATALOG"
}

_plan_field() { _row_field plan PLAN-001 "$1"; }
_spec_field() { _row_field spec SPEC-001 "$1"; }

@test "ledger-update writes the patched merged_at and pr_number, stamps status_changed_at only on a status change, preserves every other field, and patches only the row of the id kind" {
  run _update PLAN-001 '{"status":"merged","merged_at":"2026-07-05T00:00:00Z","pr_number":321}'
  [ "$status" -eq 0 ]
  [ "$(_plan_field status)" = "merged" ]
  [ "$(_plan_field merged_at)" = "2026-07-05T00:00:00Z" ]
  [ "$(_plan_field pr_number)" = "321" ]
  [ "$(_plan_field id)" = "PLAN-001" ]
  [ "$(_plan_field created_at)" = "2026-01-01T00:00:00Z" ]
  [ "$(_plan_field source)" = "allocated" ]
  [ "$(_plan_field subject)" = "x" ]

  reset_sandbox
  run _update SPEC-001 '{"status":"ready"}'
  [ "$status" -eq 0 ]
  [ "$(_spec_field status)" = "ready" ]
  [ "$(_spec_field status_changed_at)" != "2026-01-01T00:00:00Z" ]
  [ "$(_spec_field status_changed_at)" != "null" ]
  [ "$(_spec_field reservation)" = "provisional" ]
  [ "$(_spec_field intent)" = "keep me" ]
  [ "$(jq -c '.items[] | select(.id == "SPEC-001") | .custom_field' "$CATALOG")" = '{"nested":true}' ]

  reset_sandbox
  run _update PLAN-001 '{"subject":"new subject"}'
  [ "$status" -eq 0 ]
  [ "$(_plan_field subject)" = "new subject" ]
  [ "$(_plan_field status)" = "ready" ]
  [ "$(_plan_field status_changed_at)" = "2026-01-01T00:00:00Z" ]

  reset_sandbox
  before="$(jq -c '.items[] | select(.id == "PLAN-001")' "$CATALOG")"
  run _update SPEC-001 '{"status":"abandoned"}'
  [ "$status" -eq 0 ]
  [ "$(_spec_field status)" = "abandoned" ]
  [ "$(jq -c '.items[] | select(.id == "PLAN-001")' "$CATALOG")" = "$before" ]
}

@test "ledger-update accepts ready merged abandoned for a plan and rejects every other status with exit 6 and the catalog untouched" {
  run _update PLAN-001 '{"status":"bogus"}'
  [ "$status" -eq 6 ]
  grep -qF "non-canonical status 'bogus'" <<<"$output"
  [ "$(_plan_field status)" = "ready" ]

  reset_sandbox
  before="$(snapshot_file "$CATALOG")"
  run _update PLAN-001 '{"status":"draft"}'
  [ "$status" -eq 6 ]
  assert_files_identical "$CATALOG" "$before"

  reset_sandbox
  for status_name in ready merged abandoned; do
    run _update PLAN-001 "{\"status\":\"$status_name\"}"
    [ "$status" -eq 0 ]
    [ "$(_plan_field status)" = "$status_name" ]
  done

  reset_sandbox
  for status_name in allocated completed specified; do
    run _update PLAN-001 "{\"status\":\"$status_name\"}"
    [ "$status" -eq 6 ]
    grep -qF "non-canonical status '$status_name'" <<<"$output"
  done
}

@test "ledger-update exits 4 for a missing row and 5 for malformed patch JSON, and writes nothing" {
  before="$(snapshot_file "$CATALOG")"
  run _update PLAN-999 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  assert_files_identical "$CATALOG" "$before"
  run _update PLAN-001 'not json'
  [ "$status" -eq 5 ]
  run _update PLAN-001 '[1,2]'
  [ "$status" -eq 5 ]
  assert_files_identical "$CATALOG" "$before"
}

# bats test_tags=protected
@test "ledger-update fails closed with exit 4 when the notebook or ledger library is missing or unparseable, for every id" {
  before="$(snapshot_file "$CATALOG")"
  rm "$SANDBOX/.gaia/scripts/notebook/notebook-lib.sh"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  grep -qF "ledger-update: the notebook library is unusable" <<<"$output"
  assert_files_identical "$CATALOG" "$before"

  reset_sandbox
  printf 'gaia_notebook_update() { if then\n' > "$SANDBOX/.gaia/scripts/notebook/notebook-lib.sh"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  grep -qF "ledger-update: the notebook library is unusable" <<<"$output"
  assert_files_identical "$CATALOG" "$before"

  for lib_state in missing unparseable; do
    reset_sandbox
    if [ "$lib_state" = missing ]; then
      rm -f "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh"
    else
      printf 'gaia_ledger_kind_for_id() { if then\n' > "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh"
    fi
    for ledger_id in PLAN-001 SPEC-001 FOO-1; do
      run _update "$ledger_id" '{"status":"merged"}'
      [ "$status" -eq 4 ]
      grep -qF "ledger-update: the shared ledger library is unusable" <<<"$output"
    done
  done
  assert_files_identical "$CATALOG" "$before"
}

@test "ledger-update does not wait on a held mint lock and times out with exit 4 and no write on a held catalog lock" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 GAIA_LEDGER_LOCK_POLL_SECONDS=0.05
  mkdir -p "$SANDBOX/.gaia/local/cache/shared/notebook-locks/mint-spec/specs.lock.d"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 0 ]
  [ "$(_plan_field status)" = "merged" ]

  reset_sandbox
  export GAIA_LEDGER_LOCK_STALE_SECONDS=600
  mkdir -p "$SANDBOX/.gaia/local/cache/shared/notebook-locks/catalog/specs.lock.d"
  before="$(snapshot_file "$CATALOG")"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  grep -qF "could not acquire the catalog lock" <<<"$output"
  assert_files_identical "$CATALOG" "$before"
}

# bats test_tags=protected
@test "ledger-update leaves a corrupt catalog as found with exit 4, and on a pending-move repo exits 3 naming the move command, before judging the patch, creating no notebook folder" {
  printf '{"version":1,"items":[' > "$CATALOG"
  before="$(snapshot_file "$CATALOG")"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  assert_files_identical "$CATALOG" "$before"

  rm -rf "$SANDBOX"
  SANDBOX="$("$HELPERS/tmp-notebook-repo.sh" --legacy --no-catalog)"
  CATALOG="$SANDBOX/.notebook/catalog.json"
  [ ! -e "$SANDBOX/.notebook" ]
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 3 ]
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$output"
  [ ! -e "$SANDBOX/.notebook" ]
  run _update PLAN-001 'not json'
  [ "$status" -eq 3 ]
  run _update PLAN-001 '{"status":"bogus"}'
  [ "$status" -eq 3 ]
}

@test "15: called with a linked worktree as repo_root, the update lands in the main catalog" {
  rm -rf "$SANDBOX"
  local created
  created="$("$HELPERS/tmp-notebook-repo.sh" --seed-plan PLAN-001 ready --worktree wt)"
  SANDBOX="$(printf '%s\n' "$created" | sed -n 1p)"
  worktree_directory="$(printf '%s\n' "$created" | sed -n 2p)"
  CATALOG="$SANDBOX/.notebook/catalog.json"
  run bash "$worktree_directory/.gaia/scripts/spec/ledger-update.sh" "$worktree_directory" PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 0 ]
  [ "$(_plan_field status)" = "merged" ]
  [ -L "$worktree_directory/.notebook" ]
}
