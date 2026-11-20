#!/usr/bin/env bats
# Canonical-status-vocabulary tests for the SPEC rows of the notebook catalog.
#
# Concerns:
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
#   3. Frontmatter status: spec/lint.sh holds a SPEC file's own status to its
#      own vocabulary, accepting in-progress and refusing ready as bad_status.
#
# Canonical vocabulary is documented in wiki/concepts/GAIA Spec.md
# ("Ledger status vocabulary"). Keep WRITABLE below in sync with that section.
#
# Each behavioral test spins up one tmp git repo via
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

# _spec_field <id> <field>: one spec row's field, read straight from the catalog.
_spec_field() {
  jq -r --arg id "$1" --arg field "$2" '.items[] | select(.kind == "spec" and .id == $id) | .[$field]' "$(_catalog)"
}

# The first spec row's field, read straight from the catalog file.
_first_spec_field() {
  jq -r --arg field "$1" '[.items[] | select(.kind == "spec")][0][$field]' "$(_catalog)"
}

# bats test_tags=protected
@test "ledger-update accepts every writable status and a status-less patch, and rejects a non-canonical or retired status with exit 6" {
  # One repo for every case. The rejections and the status-less patch run
  # while the row is still draft; the writable statuses run last because each
  # accepted write changes the row.
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"

  echo "case: a non-canonical status is rejected with exit 6 and the catalog is unchanged"
  before="$(snapshot_file "$(_catalog)")"
  run _ledger_update "$REPO" SPEC-001 '{"status":"shipped"}'
  [ "$status" -eq 6 ]
  [[ "$output" == *"non-canonical status 'shipped'"* ]]
  assert_files_identical "$(_catalog)" "$before"

  for retired_status in $RETIRED; do
    echo "case: the retired status $retired_status is rejected with exit 6"
    run _ledger_update "$REPO" SPEC-001 "{\"status\":\"$retired_status\"}"
    [ "$status" -eq 6 ]
    grep -qF "non-canonical status '$retired_status'" <<<"$output"
  done

  echo "case: a status-less patch (merged_at only) passes the guard"
  run _ledger_update "$REPO" SPEC-001 '{"merged_at":"2026-01-02T00:00:00Z"}'
  [ "$status" -eq 0 ]
  [ "$(_first_spec_field merged_at)" = "2026-01-02T00:00:00Z" ]
  [ "$(_first_spec_field status)" = "draft" ]

  for writable_status in $WRITABLE; do
    echo "case: the writable status $writable_status is accepted"
    run _ledger_update "$REPO" SPEC-001 "{\"status\":\"$writable_status\"}"
    [ "$status" -eq 0 ]
    [ "$(_first_spec_field status)" = "$writable_status" ]
  done
}

@test "spec-reconcile renames shipped to merged and leaves an unrecognized status untouched with a warning" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 shipped --seed-spec SPEC-002 bogus-status)"
  run _reconcile "$REPO"
  [ "$status" -eq 0 ]

  echo "case: a planted shipped row is renamed to merged"
  [[ "$output" == *"normalized SPEC-001: shipped -> merged"* ]]
  [ "$(_spec_field SPEC-001 status)" = "merged" ]

  echo "case: an unrecognized status is left untouched and warned about"
  [[ "$output" == *"unrecognized status bogus-status"* ]]
  [ "$(_spec_field SPEC-002 status)" = "bogus-status" ]
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
flows:
  - flow_id: FLOW-001
    slug: example
    name: example flow
    why: example reason
    test_path: .gaia/tests/lib/example.bats
scope_boundaries: test scope
clarifications: none
research_summary: none
created: 2026-01-01
updated: 2026-01-01
---

# Test SPEC

## Behaviors

- **B1** (access): A signed-out visitor cannot open the dashboard.
  - Case: signed-out visitor requests the dashboard -> redirected to sign-in.
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
