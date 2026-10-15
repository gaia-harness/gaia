#!/usr/bin/env bats
# Tests for `.gaia/scripts/spec/ledger-update.sh`: the single guarded status
# chokepoint over the notebook catalog rows of both kinds, after the initial
# allocation. Covers the plan-row stamps, cross-kind routing, the readiness and
# corrupt-catalog refusals, the fail-closed library probes and lock scope.
#
# Each case runs against a tmp repo from helpers/tmp-notebook-repo.sh, so the
# real catalog is never touched.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  HELPERS="$THIS_DIRECTORY/helpers"
  SANDBOX="$("$HELPERS/tmp-notebook-repo.sh" \
    --seed-row '{"kind":"plan","id":"PLAN-001","path":"plans/PLAN-001","status":"ready","subject":"x","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z","source":"allocated"}' \
    --seed-row '{"kind":"spec","id":"SPEC-001","path":"specs/SPEC-001","status":"draft","subject":"y","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z","reservation":"provisional","intent":"keep me","custom_field":{"nested":true}}')"
  CATALOG="$SANDBOX/.notebook/catalog.json"
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    rm -rf "$SANDBOX" "${SANDBOX}-wt" "${SANDBOX}-other"
  fi
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

@test "1: a plan merged patch stamps merged_at and pr_number and preserves other fields" {
  run _update PLAN-001 '{"status":"merged","merged_at":"2026-07-05T00:00:00Z","pr_number":321}'
  [ "$status" -eq 0 ]
  [ "$(_plan_field status)" = "merged" ]
  [ "$(_plan_field merged_at)" = "2026-07-05T00:00:00Z" ]
  [ "$(_plan_field pr_number)" = "321" ]
  [ "$(_plan_field id)" = "PLAN-001" ]
  [ "$(_plan_field created_at)" = "2026-01-01T00:00:00Z" ]
  [ "$(_plan_field source)" = "allocated" ]
  [ "$(_plan_field subject)" = "x" ]
}

@test "1b: a spec draft to ready flip stamps status_changed_at and keeps reservation, intent and an unknown field" {
  run _update SPEC-001 '{"status":"ready"}'
  [ "$status" -eq 0 ]
  [ "$(_spec_field status)" = "ready" ]
  [ "$(_spec_field status_changed_at)" != "2026-01-01T00:00:00Z" ]
  [ "$(_spec_field status_changed_at)" != "null" ]
  [ "$(_spec_field reservation)" = "provisional" ]
  [ "$(_spec_field intent)" = "keep me" ]
  [ "$(jq -c '.items[] | select(.id == "SPEC-001") | .custom_field' "$CATALOG")" = '{"nested":true}' ]
}

@test "2: non-canonical status exits 6 and leaves status unchanged" {
  run _update PLAN-001 '{"status":"bogus"}'
  [ "$status" -eq 6 ]
  grep -qF "non-canonical status 'bogus'" <<<"$output"
  [ "$(_plan_field status)" = "ready" ]
}

@test "2b: draft is a spec-only status, rejected for a plan with the catalog untouched" {
  before="$(snapshot_file "$CATALOG")"
  run _update PLAN-001 '{"status":"draft"}'
  [ "$status" -eq 6 ]
  assert_files_identical "$CATALOG" "$before"
}

@test "3: a status-less patch updates only the targeted field, status and its stamp untouched" {
  run _update PLAN-001 '{"subject":"new subject"}'
  [ "$status" -eq 0 ]
  [ "$(_plan_field subject)" = "new subject" ]
  [ "$(_plan_field status)" = "ready" ]
  [ "$(_plan_field status_changed_at)" = "2026-01-01T00:00:00Z" ]
}

@test "4: a patch for a missing row exits 4 and the catalog is byte-identical" {
  before="$(snapshot_file "$CATALOG")"
  run _update PLAN-999 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  assert_files_identical "$CATALOG" "$before"
}

@test "5: malformed patch JSON exits 5 with the catalog untouched" {
  before="$(snapshot_file "$CATALOG")"
  run _update PLAN-001 'not json'
  [ "$status" -eq 5 ]
  run _update PLAN-001 '[1,2]'
  [ "$status" -eq 5 ]
  assert_files_identical "$CATALOG" "$before"
}

@test "6: ready, merged, and abandoned are all accepted for a plan" {
  for status_name in ready merged abandoned; do
    run _update PLAN-001 "{\"status\":\"$status_name\"}"
    [ "$status" -eq 0 ]
    [ "$(_plan_field status)" = "$status_name" ]
  done
}

@test "6b: allocated, completed, and specified are all rejected with exit 6" {
  for status_name in allocated completed specified; do
    run _update PLAN-001 "{\"status\":\"$status_name\"}"
    [ "$status" -eq 6 ]
    grep -qF "non-canonical status '$status_name'" <<<"$output"
  done
}

@test "7: wrong arg count exits 2" {
  run bash "$SANDBOX/.gaia/scripts/spec/ledger-update.sh" "$SANDBOX" PLAN-001
  [ "$status" -eq 2 ]
}

@test "8: a SPEC id patches the spec row and leaves the plan row alone" {
  before="$(jq -c '.items[] | select(.id == "PLAN-001")' "$CATALOG")"
  run _update SPEC-001 '{"status":"abandoned"}'
  [ "$status" -eq 0 ]
  [ "$(_spec_field status)" = "abandoned" ]
  [ "$(jq -c '.items[] | select(.id == "PLAN-001")' "$CATALOG")" = "$before" ]
}

@test "9: an id matching neither prefix exits 2 and writes nothing" {
  before="$(snapshot_file "$CATALOG")"
  for bad_id in FOO-1 plan-001 ""; do
    run _update "$bad_id" '{"status":"merged"}'
    [ "$status" -eq 2 ]
  done
  assert_files_identical "$CATALOG" "$before"
}

@test "10: a missing notebook library fails closed with exit 4 for a plan id" {
  rm "$SANDBOX/.gaia/scripts/notebook/notebook-lib.sh"
  before="$(snapshot_file "$CATALOG")"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  grep -qF "ledger-update: the notebook library is unusable" <<<"$output"
  assert_files_identical "$CATALOG" "$before"
}

@test "10b: an unparseable notebook library fails closed with exit 4 for a plan id" {
  printf 'gaia_notebook_update() { if then\n' > "$SANDBOX/.gaia/scripts/notebook/notebook-lib.sh"
  before="$(snapshot_file "$CATALOG")"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  grep -qF "ledger-update: the notebook library is unusable" <<<"$output"
  assert_files_identical "$CATALOG" "$before"
}

@test "11: a missing or unparseable ledger-lib.sh fails closed with exit 4 for every id, even one matching neither prefix" {
  before="$(snapshot_file "$CATALOG")"
  for lib_state in missing unparseable; do
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

@test "12: a plan update does not wait on a held mint lock" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 GAIA_LEDGER_LOCK_POLL_SECONDS=0.05
  mkdir -p "$SANDBOX/.gaia/local/cache/shared/notebook-locks/mint-spec/specs.lock.d"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 0 ]
  [ "$(_plan_field status)" = "merged" ]
}

@test "12b: a held catalog lock times an update out with exit 4 and no write" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 GAIA_LEDGER_LOCK_POLL_SECONDS=0.05 GAIA_LEDGER_LOCK_STALE_SECONDS=600
  mkdir -p "$SANDBOX/.gaia/local/cache/shared/notebook-locks/catalog/specs.lock.d"
  before="$(snapshot_file "$CATALOG")"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  grep -qF "could not acquire the catalog lock" <<<"$output"
  assert_files_identical "$CATALOG" "$before"
}

@test "13: a repo whose one-time move is pending exits 3 naming the move command and creates no notebook folder" {
  rm -rf "$SANDBOX"
  SANDBOX="$("$HELPERS/tmp-notebook-repo.sh" --legacy --no-catalog)"
  CATALOG="$SANDBOX/.notebook/catalog.json"
  [ ! -e "$SANDBOX/.notebook" ]
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 3 ]
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$output"
  [ ! -e "$SANDBOX/.notebook" ]
}

@test "13b: readiness is checked before the patch is judged, so a bad patch on a pending repo still exits 3" {
  rm -rf "$SANDBOX"
  SANDBOX="$("$HELPERS/tmp-notebook-repo.sh" --legacy --no-catalog)"
  run _update PLAN-001 'not json'
  [ "$status" -eq 3 ]
  run _update PLAN-001 '{"status":"bogus"}'
  [ "$status" -eq 3 ]
}

@test "14: a corrupt catalog exits 4 and is left exactly as found" {
  printf '{"version":1,"items":[' > "$CATALOG"
  before="$(snapshot_file "$CATALOG")"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  assert_files_identical "$CATALOG" "$before"
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
