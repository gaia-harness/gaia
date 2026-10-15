#!/usr/bin/env bats
# Canonical-status-vocabulary tests for the SPEC rows of the notebook catalog.
#
# Three concerns:
#   1. Behavioral guard: ledger-update.sh (the single chokepoint for status
#      writes) accepts the four canonical statuses {draft, ready, merged,
#      abandoned}, and rejects anything else (including the retired
#      specified/archived/in-progress/allocated/completed values) with exit 6.
#      This guard ships to adopters, so it protects every tool-path write on
#      every clone.
#   2. Auto-fix: spec-reconcile.sh renames a known-misnamed status (shipped ->
#      merged) to canonical through that same chokepoint, and leaves an
#      unrecognized status untouched (logging it). This repairs the hand-edit /
#      backfill vector the guard cannot see (raw edits bypass the chokepoint),
#      and it also ships to adopters (runs on every /gaia-spec).
#   3. Data integrity: the real project catalog carries no off-vocabulary spec
#      status row.
#
# Canonical vocabulary is documented in wiki/concepts/GAIA Spec.md
# ("Ledger status vocabulary"). Keep WRITABLE below in sync with that section.
#
# Each behavioral test spins up its own tmp git repo via
# helpers/tmp-notebook-repo.sh and tears it down; hermetic, no reliance on the
# real project notebook. The teardown uses the explicit-if form (the && idiom
# is a bats teardown footgun: a falsy first clause makes teardown itself
# "fail").

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$BATS_TEST_DIRNAME/../helpers/files.sh"
  # Statuses ledger-update.sh accepts: the four canonical unified values.
  WRITABLE="draft ready merged abandoned"
  # Retired values the guard now rejects (superseded by the unified vocabulary).
  RETIRED="specified archived in-progress allocated completed"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

_ledger_update() {
  bash "$REPO/.gaia/scripts/spec/ledger-update.sh" "$@"
}

_reconcile() {
  bash "$REPO/.gaia/scripts/spec/spec-reconcile.sh" "$@"
}

_catalog() {
  printf '%s\n' "$REPO/.notebook/catalog.json"
}

# The first spec row's field, read straight from the catalog file.
_first_spec_field() {
  jq -r --arg field "$1" '[.items[] | select(.kind == "spec")][0][$field]' "$(_catalog)"
}

# A spec row seeded with a status the guard would refuse to write, standing in
# for a pre-guard or hand-edited row.
_seed_with_status() {
  "$HELPERS/tmp-notebook-repo.sh" --seed-spec "$1" "$2"
}

@test "1: non-canonical status is rejected with exit 6" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  run _ledger_update "$REPO" SPEC-001 '{"status":"shipped"}'
  [ "$status" -eq 6 ]
  [[ "$output" == *"non-canonical status 'shipped'"* ]]
}

@test "2: a rejected patch leaves the catalog byte-for-byte unchanged" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  before="$(snapshot_file "$(_catalog)")"
  run _ledger_update "$REPO" SPEC-001 '{"status":"shipped"}'
  [ "$status" -eq 6 ]
  assert_files_identical "$(_catalog)" "$before"
}

@test "3: every writable status (the unified vocabulary) is accepted" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  for writable_status in $WRITABLE; do
    run _ledger_update "$REPO" SPEC-001 "{\"status\":\"$writable_status\"}"
    [ "$status" -eq 0 ]
    [ "$(_first_spec_field status)" = "$writable_status" ]
  done
}

@test "3b: every retired status is rejected with exit 6" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  for retired_status in $RETIRED; do
    run _ledger_update "$REPO" SPEC-001 "{\"status\":\"$retired_status\"}"
    [ "$status" -eq 6 ]
    grep -qF "non-canonical status '$retired_status'" <<<"$output"
  done
}

@test "4: a status-less patch (merged_at only) passes the guard" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  run _ledger_update "$REPO" SPEC-001 '{"merged_at":"2026-01-02T00:00:00Z"}'
  [ "$status" -eq 0 ]
  [ "$(_first_spec_field merged_at)" = "2026-01-02T00:00:00Z" ]
  [ "$(_first_spec_field status)" = "draft" ]
}

@test "5: spec-reconcile renames a planted 'shipped' row to 'merged'" {
  REPO="$(_seed_with_status SPEC-001 shipped)"
  run _reconcile "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"normalized SPEC-001: shipped -> merged"* ]]
  [ "$(_first_spec_field status)" = "merged" ]
}

@test "6: spec-reconcile leaves an unrecognized status untouched and warns" {
  REPO="$(_seed_with_status SPEC-001 bogus-status)"
  run _reconcile "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unrecognized status bogus-status"* ]]
  [ "$(_first_spec_field status)" = "bogus-status" ]
}

@test "7: the real project catalog carries only writable spec statuses" {
  root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  notebook_root="$(GAIA_NOTEBOOK_TREE="$root" bash "$root/.gaia/scripts/notebook/notebook-lib.sh" root 2>/dev/null)" || skip "no resolvable notebook"
  catalog="$notebook_root/catalog.json"
  [ -f "$catalog" ] || skip "no project catalog at $catalog"
  bad="$(jq -r --arg writable "$WRITABLE" '
    ($writable | split(" ")) as $ok
    | .items[] | select(.kind == "spec")
    | select(.status as $row_status | $ok | index($row_status) | not)
    | .id + ":" + (.status // "null")
  ' "$catalog")"
  [ -z "$bad" ] || {
    echo "off-vocabulary catalog rows: $bad" >&2
    false
  }
}

# --- 8: the SPEC-artifact frontmatter axis stays distinct from the row axis
#
# lint.sh validates a wholly separate status axis (the SPEC artifact's own
# authoring lifecycle, in-progress|reopened|closed), never the row
# vocabulary this suite covers. Belt-and-suspenders: confirms the guard's
# unified vocabulary was never leaked into lint.sh's enum.
_lint_fixture() {
  local status_value="$1"
  cat <<EOF
---
spec_id: SPEC-999
type: feature
status: $status_value
immutable: true
wiki_promote_default: ask
chain_trigger: none
intent: test intent
success_criteria: test criteria
uats: []
scope_boundaries: test scope
clarifications: none
research_summary: none
created: 2026-01-01
updated: 2026-01-01
---

# Test SPEC
EOF
}

@test "8: lint.sh accepts status in-progress and rejects status ready (bad_status)" {
  root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  lint="$root/.gaia/scripts/spec/lint.sh"
  fixture="$(mktemp)"

  _lint_fixture "in-progress" > "$fixture"
  run bash "$lint" "$fixture"
  [ "$status" -eq 0 ]

  _lint_fixture "ready" > "$fixture"
  run bash "$lint" "$fixture"
  [ "$status" -eq 1 ]
  grep -qF '"bad_status"' <<<"$output"

  rm -f "$fixture"
}
