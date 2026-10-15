#!/usr/bin/env bats
# Delete-sweep tests for plan-archive-merged.sh, the plans-side mirror of
# spec-archive-merged.sh (see spec-archive-merged.bats for the shared design
# notes: age gate, consolidation gate, usage-ledger gate).
#
# Per-test fixture via helpers/tmp-notebook-repo.sh: a throwaway git repo that
# carries the notebook library, the usage-gate scripts and an empty catalog, so
# every sweep touches only throwaway fixtures. The usage-ledger gate reads the
# fixture's own usage.jsonl; the happy-path seed adds the gaia-plan close it
# needs.
#
# By the time a plan reaches this sweep it has already been reduced to
# SUMMARY.md by plan-archive.sh, so the seeded happy-path fixture
# is SUMMARY.md-only (no SPEC.md); the consolidation-gate tests below add
# SPEC.md back in to exercise the defensive keep case.
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# Builds the throwaway fixture repository the suite acts on.
_fixture_repository() {
  "$THIS_DIRECTORY/helpers/tmp-notebook-repo.sh" "$@"
}

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  ARCHIVE_SOURCE="$REPO_ROOT/.gaia/scripts/spec/plan-archive-merged.sh"
  [ -x "$ARCHIVE_SOURCE" ] || skip "plan-archive-merged.sh not executable"
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  # shellcheck source=helpers/usage-gate.sh
  . "$THIS_DIRECTORY/helpers/usage-gate.sh"

  SANDBOX="$(_fixture_repository)"

  PLANS="$SANDBOX/.notebook/plans"
  CATALOG="$SANDBOX/.notebook/catalog.json"
  TELEMETRY="$SANDBOX/.gaia/local/telemetry"
  mkdir -p "$PLANS"

  # A fixed merged_at ("2026-01-02T00:00:00Z"), so every reap test below needs
  # the age gate collapsed to stay deterministic regardless of wall-clock
  # time. The age-gate tests re-export this per test to exercise the window.
  export GAIA_SPEC_RETENTION_DAYS=0
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    rm -rf "$SANDBOX"
  fi
  if [ -n "${LINKED:-}" ]; then
    rm -rf "$LINKED"
  fi
}

_archive() {
  bash "$SANDBOX/.gaia/scripts/spec/plan-archive-merged.sh" "$@"
}

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

refute_contains() {
  if grep -qF -- "$1" <<<"$output"; then
    echo "unexpected match: $1" >&2
    return 1
  fi
}

# _patch_catalog <jq-filter> [jq args...]: rewrite the catalog in place.
_patch_catalog() {
  local filter="$1" temporary_file
  shift
  temporary_file="$(mktemp)"
  jq "$@" "$filter" "$CATALOG" > "$temporary_file"
  mv "$temporary_file" "$CATALOG"
}

# _seed_merged_row_only <plan_id>: a merged catalog row with NO folder (the
# archive-sweep skip-no-folder case).
_seed_merged_row_only() {
  _patch_catalog '.items += [{kind: "plan", id: $id, path: ("plans/" + $id), status: "merged", subject: $id, source: "allocated", created_at: "2026-01-01T00:00:00Z", status_changed_at: "2026-01-02T00:00:00Z", merged_at: "2026-01-02T00:00:00Z"}]' --arg id "$1"
}

# _seed_merged_plan <plan_id> [unrecorded]: appends a merged catalog row AND
# writes the already-consolidated folder shape (SUMMARY.md only), the sweep's
# happy-path fixture, plus the gaia-plan close the usage-ledger gate needs
# unless the second argument is "unrecorded".
_seed_merged_plan() {
  local id="$1"
  [ "${2:-}" = unrecorded ] || seed_close_row "$TELEMETRY" "plan:$id" gaia-plan
  _seed_merged_row_only "$id"
  mkdir -p "$PLANS/$id"
  cat > "$PLANS/$id/SUMMARY.md" <<EOF
---
wiki_promote_default: ask
wiki_promote_targets: []
---
# $id

Consolidated summary body.
EOF
}

# _write_summary <folder>: a well-formed consolidated SUMMARY.md.
_write_summary() {
  cat > "$1/SUMMARY.md" <<EOF
---
wiki_promote_default: ask
wiki_promote_targets: []
---
# Summary

Consolidated summary body.
EOF
}

# _seed_folder_only <plan_id>: a folder with no catalog row (the sweep is
# row-driven, so it stays active).
_seed_folder_only() {
  local id="$1"
  mkdir -p "$PLANS/$id"
  printf 'summary\n' > "$PLANS/$id/SUMMARY.md"
}

# _set_merged_at / _clear_merged_at <plan_id> [<iso>]: patch the seeded
# catalog row's merged_at, for age-window and fail-closed tests.
_set_merged_at() {
  _patch_catalog '.items |= map(if .kind == "plan" and .id == $id then . + {merged_at: $timestamp} else . end)' --arg id "$1" --arg timestamp "$2"
}

_clear_merged_at() {
  _patch_catalog '.items |= map(if .kind == "plan" and .id == $id then del(.merged_at) else . end)' --arg id "$1"
}

# _set_pr_number <plan_id> <number>: stamp the confirmed pr_number on a row.
_set_pr_number() {
  _patch_catalog '.items |= map(if .kind == "plan" and .id == $id then . + {pr_number: $number} else . end)' --arg id "$1" --argjson number "$2"
}

# _set_status <plan_id> <status>: rewrite a row's status.
_set_status() {
  _patch_catalog '.items |= map(if .kind == "plan" and .id == $id then . + {status: $value} else . end)' --arg id "$1" --arg value "$2"
}

# _row_field <plan_id> <field>: one field of a plan row, "none" when absent.
_row_field() {
  jq -r --arg id "$1" --arg field_name "$2" \
    '.items[] | select(.kind == "plan" and .id == $id) | .[$field_name] // "none"' "$CATALOG"
}

# _snapshot: every path under the sandbox except git's own store, plus the
# catalog bytes, for before/after comparison.
_snapshot() {
  find "$SANDBOX" -path "$SANDBOX/.git" -prune -o -print | LC_ALL=C sort
  cksum < "$CATALOG"
}

# _days_ago <days>: portable ISO8601 timestamp that many days in the past, computed with
# jq (never `date -d`/`date -j`), matching spec-archive-merged.bats.
_days_ago() {
  jq -rn --argjson days "$1" '(now - ($days * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# --- 1: delete happy path (SUMMARY.md-only, run recorded) ------------------

@test "1: a merged row whose run is on the usage ledger is deleted; the row keeps its stamp and gains a reap record" {
  _seed_merged_plan PLAN-001

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]

  # Row stamp untouched: still merged, merged_at unchanged (the stamp is a
  # precondition, not set by this sweep). The reap record names this script.
  [ "$(_row_field PLAN-001 status)" = "merged" ]
  [ "$(_row_field PLAN-001 merged_at)" = "2026-01-02T00:00:00Z" ]
  [ "$(jq -r '.items[] | select(.id == "PLAN-001") | .reap.by' "$CATALOG")" = "plan-archive-merged" ]
  [ "$(jq -r '.items[] | select(.id == "PLAN-001") | .reap.at | test("^[0-9]{4}-")' "$CATALOG")" = "true" ]
}

# --- 2: single-id filter narrows the sweep -----------------------------------

@test "2: the single-id form deletes only the named plan" {
  _seed_merged_plan PLAN-001
  _seed_merged_plan PLAN-002

  run _archive "$SANDBOX" PLAN-001
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
  [ -d "$PLANS/PLAN-002" ]
  [ "$(_row_field PLAN-002 reap)" = "none" ]
}

# --- 5: the retired defer cache no longer blocks a reap ----------------------

@test "5: a leftover wiki-promote defer cache file beside a reapable plan no longer blocks its reap" {
  _seed_merged_plan PLAN-001
  mkdir -p "$SANDBOX/.gaia/local/cache/wiki-promote"
  printf '{"branch":"plan-1-x"}\n' > "$SANDBOX/.gaia/local/cache/wiki-promote/PLAN-001.json"

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"

  [ ! -e "$PLANS/PLAN-001" ]
  # The sweep neither reads nor purges the retired path.
  [ -f "$SANDBOX/.gaia/local/cache/wiki-promote/PLAN-001.json" ]
}


@test "6: a merged row with no active folder is a no-op" {
  _seed_merged_row_only PLAN-005

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ "$(_row_field PLAN-005 reap)" = "none" ]
}

# --- 7: idempotent re-run ----------------------------------------------------

@test "7: re-running the sweep after deleting is a no-op" {
  _seed_merged_plan PLAN-001

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 8: only merged rows with folders are swept ------------------------------

@test "8: a folder without a merged catalog row is never deleted" {
  _seed_merged_plan PLAN-001
  _seed_folder_only PLAN-002

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"

  [ ! -e "$PLANS/PLAN-001" ]
  # PLAN-002 untouched: still active, never deleted.
  [ -f "$PLANS/PLAN-002/SUMMARY.md" ]
}

# --- 9: multiple merged folders in one sweep --------------------------------

@test "9: two merged folders are deleted together with a combined summary" {
  _seed_merged_plan PLAN-001
  _seed_merged_plan PLAN-002

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 2 merged plan folder(s): PLAN-001, PLAN-002"
  [ ! -e "$PLANS/PLAN-001" ]
  [ ! -e "$PLANS/PLAN-002" ]
}

# --- 10: no merged rows -> clean no-op ---------------------------------------

@test "10: a repo with no merged rows produces no output and exits 0" {
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 11: age gate, within window -> kept -------------------------------------

@test "11: a merged folder within the retention window is kept, not deleted" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 2)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "PLAN-001 within retention window (or merged_at missing/unparseable); kept"

  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]
}


@test "12: a merged folder past the retention window with its run recorded is reaped" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]

  [ "$(_row_field PLAN-001 status)" = "merged" ]
}


# --- 14/15: missing or unparseable merged_at -> kept regardless -------------

@test "14: a merged row with no merged_at is kept regardless of representation" {
  _seed_merged_plan PLAN-001
  _clear_merged_at PLAN-001
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "PLAN-001 within retention window (or merged_at missing/unparseable); kept"

  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]
}

@test "15: a merged row with an unparseable merged_at is kept regardless of representation" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "not-a-timestamp"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "PLAN-001 within retention window (or merged_at missing/unparseable); kept"

  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]
}

# --- 16/17: GAIA_SPEC_RETENTION_DAYS knob is honored --------------------------

@test "16: GAIA_SPEC_RETENTION_DAYS=0 reaps a just-merged recorded folder" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 0)"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
}

@test "17: GAIA_SPEC_RETENTION_DAYS=99999 keeps an old merged folder" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 400)"
  export GAIA_SPEC_RETENTION_DAYS=99999

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"

  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]
}


@test "18: a non-numeric GAIA_SPEC_RETENTION_DAYS falls back to the 30-day default" {
  export GAIA_SPEC_RETENTION_DAYS="abc"

  # Within the 30-day fallback: kept (proves the fallback isn't 0).
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 10)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]

  # Past the 30-day fallback: reaped (proves the fallback isn't unbounded).
  _seed_merged_plan PLAN-002
  _set_merged_at PLAN-002 "$(_days_ago 45)"
  run _archive "$SANDBOX" PLAN-002
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-002"
}

# --- 19: --close is accepted and ignored: no early reap ----------------------

@test "19: a within-window PLAN-007 stays kept with and without --close" {
  _seed_merged_plan PLAN-007
  _set_merged_at PLAN-007 "$(_days_ago 2)"
  _set_pr_number PLAN-007 2601
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX" PLAN-007
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-007" ]

  run _archive "$SANDBOX" PLAN-007 --close
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-007" ]
}

@test "20: --close does not bypass the consolidation gate" {
  _seed_merged_plan PLAN-002
  rm -f "$PLANS/PLAN-002/SUMMARY.md"
  printf '# Spec\n' > "$PLANS/PLAN-002/SPEC.md"

  run _archive "$SANDBOX" PLAN-002 --close
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-002" ]
}

# --- 21: consolidation gate keeps a SPEC.md/no-SUMMARY.md shape -------------

@test "21: a folder holding SPEC.md with no SUMMARY.md is kept past the window even when its run is recorded (defensive)" {
  _seed_merged_plan PLAN-001
  rm -f "$PLANS/PLAN-001/SUMMARY.md"
  printf '# Spec\n' > "$PLANS/PLAN-001/SPEC.md"
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept PLAN-001"

  [ -f "$PLANS/PLAN-001/SPEC.md" ]
}

# --- 22: real delegation to summary-verify.sh, not just the fallback -------

@test "22: prefers summary-verify.sh when present; a malformed but non-empty SUMMARY.md is kept" {
  [ -f "$REPO_ROOT/.gaia/scripts/summary-verify.sh" ] || skip "summary-verify.sh not present yet"
  cp "$REPO_ROOT/.gaia/scripts/summary-verify.sh" "$SANDBOX/.gaia/scripts/summary-verify.sh"

  _seed_merged_plan PLAN-001
  printf '# Spec\n' > "$PLANS/PLAN-001/SPEC.md"
  # Non-empty but malformed content (no frontmatter/H1). A plain
  # [ -s SUMMARY.md ] fallback would wrongly pass this; only real delegation
  # to summary-verify.sh catches the malformed shape.
  printf 'not frontmatter, not well-formed\n' > "$PLANS/PLAN-001/SUMMARY.md"
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept PLAN-001"
}

# --- 23-24: the two reap arms -----------------------------------------------

@test "23: confirmed arm: a row with pr_number and an aged merged_at is reaped; inside the window it is kept" {
  _seed_merged_plan PLAN-001
  _set_pr_number PLAN-001 2601
  export GAIA_SPEC_RETENTION_DAYS=30

  _set_merged_at PLAN-001 "$(_days_ago 2)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]

  _set_merged_at PLAN-001 "$(_days_ago 45)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
}

@test "24: legacy arm: a merged row with no pr_number and an aged merged_at is reaped; inside the window it is kept" {
  _seed_merged_plan PLAN-001
  [ "$(_row_field PLAN-001 pr_number)" = "none" ]
  export GAIA_SPEC_RETENTION_DAYS=30

  _set_merged_at PLAN-001 "$(_days_ago 2)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]

  _set_merged_at PLAN-001 "$(_days_ago 45)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
}

@test "25: a legacy row with a missing merged_at is kept" {
  _seed_merged_plan PLAN-001
  _clear_merged_at PLAN-001
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]
}

@test "26: a legacy row with an unparseable merged_at is kept" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "last tuesday"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]
}

@test "27: a ready row (no merged_at) with an otherwise reapable folder is kept, with or without a pr_number" {
  _seed_merged_plan PLAN-001
  _clear_merged_at PLAN-001
  _set_status PLAN-001 ready
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]

  _set_pr_number PLAN-001 2601
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]
}

@test "27b: a ready row that carries a stale aged merged_at is still never a candidate" {
  _seed_merged_plan PLAN-001
  _set_status PLAN-001 ready
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]
}

# --- 28: the consolidation gate covers PROGRESS.md --------------------------

@test "28: a confirmed folder holding PROGRESS.md and no SUMMARY.md is kept; with a verified SUMMARY.md it is reaped" {
  cp "$REPO_ROOT/.gaia/scripts/summary-verify.sh" "$SANDBOX/.gaia/scripts/summary-verify.sh"
  _seed_merged_plan PLAN-001
  _set_pr_number PLAN-001 2601
  summary_text="$(cat "$PLANS/PLAN-001/SUMMARY.md")"
  rm -f "$PLANS/PLAN-001/SUMMARY.md"
  printf '## Phase 1\n' > "$PLANS/PLAN-001/PROGRESS.md"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept PLAN-001"
  [ -f "$PLANS/PLAN-001/PROGRESS.md" ]

  printf '%s\n' "$summary_text" > "$PLANS/PLAN-001/SUMMARY.md"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
}

# --- 29: a folder with no SUMMARY.md is never reaped ------------------------

@test "29: an aged, recorded folder holding only plan files and no SUMMARY.md is kept" {
  _seed_merged_plan PLAN-001
  rm -f "$PLANS/PLAN-001/SUMMARY.md"
  printf '# Plan\n' > "$PLANS/PLAN-001/PLAN.md"
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept PLAN-001"
  [ -f "$PLANS/PLAN-001/PLAN.md" ]
}

@test "30: without ledger-lib.sh the sweep reaps nothing and says so; with it the same folder is reaped" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  mv "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh" "$SANDBOX/ledger-lib.sh.aside"
  run --separate-stderr _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  grep -qF "ledger-lib.sh is unusable; nothing swept" <<<"$stderr"
  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]

  mv "$SANDBOX/ledger-lib.sh.aside" "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  [ ! -e "$PLANS/PLAN-001" ]
}

@test "31: a run missing from the usage ledger leaves its folder, prints the keep line, and the sweep still reaps the next row" {
  _seed_merged_plan PLAN-001 unrecorded
  _seed_merged_plan PLAN-002

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Kept .notebook/plans/PLAN-001: no gaia-plan run recorded for plan:PLAN-001; outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record plan:PLAN-001 --workflow gaia-plan --start <iso>"
  [ -d "$PLANS/PLAN-001" ]
  [ ! -e "$PLANS/PLAN-002" ]
}

@test "32: a missing usage ledger keeps the folder and the keep line names the ledger path" {
  _seed_merged_plan PLAN-001
  rm -f "$TELEMETRY/usage.jsonl"

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "Kept .notebook/plans/PLAN-001: usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for plan:PLAN-001; once it reads, outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record plan:PLAN-001 --workflow gaia-plan --start <iso>"
  [ -d "$PLANS/PLAN-001" ]
}

@test "33: a gaia-spec close for the same number does not clear a plan folder" {
  _seed_merged_plan PLAN-001 unrecorded
  seed_close_row "$TELEMETRY" plan:PLAN-001 gaia-spec

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "no gaia-plan run recorded for plan:PLAN-001"
  [ -d "$PLANS/PLAN-001" ]
}

# --- 34-35: the notebook is the only place the sweep looks and deletes -------

@test "34: a merged plan is deleted from the main notebook and a same-named folder in the old location is untouched" {
  _seed_merged_plan PLAN-003
  _set_pr_number PLAN-003 2601
  mkdir -p "$SANDBOX/.gaia/local/plans/PLAN-003"
  printf 'decoy\n' > "$SANDBOX/.gaia/local/plans/PLAN-003/SUMMARY.md"

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-003"
  [ ! -e "$PLANS/PLAN-003" ]
  [ "$(cat "$SANDBOX/.gaia/local/plans/PLAN-003/SUMMARY.md")" = "decoy" ]
  [ "$(_row_field PLAN-003 reap | head -c 1)" = "{" ]
}

@test "34b: run from a linked worktree, the plan is deleted from main's notebook and the old-location folder is untouched" {
  rm -rf "$SANDBOX"
  fixture="$(_fixture_repository --worktree w)"
  SANDBOX="$(printf '%s\n' "$fixture" | sed -n 1p)"
  LINKED="$(printf '%s\n' "$fixture" | sed -n 2p)"
  PLANS="$SANDBOX/.notebook/plans"
  CATALOG="$SANDBOX/.notebook/catalog.json"
  TELEMETRY="$SANDBOX/.gaia/local/telemetry"
  _seed_merged_plan PLAN-003
  _set_pr_number PLAN-003 2601
  mkdir -p "$SANDBOX/.gaia/local/plans/PLAN-003"
  printf 'decoy\n' > "$SANDBOX/.gaia/local/plans/PLAN-003/SUMMARY.md"

  run bash "$LINKED/.gaia/scripts/spec/plan-archive-merged.sh" "$LINKED"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-003"
  [ ! -e "$PLANS/PLAN-003" ]
  [ "$(cat "$SANDBOX/.gaia/local/plans/PLAN-003/SUMMARY.md")" = "decoy" ]
  [ "$(jq -r '.items[] | select(.id == "PLAN-003") | .reap.by' "$CATALOG")" = "plan-archive-merged" ]
  [ -L "$LINKED/.notebook" ]
}

@test "35: a row that already carries a reap record is skipped even when a folder is present" {
  _seed_merged_plan PLAN-001
  _patch_catalog '.items |= map(if .id == "PLAN-001" then . + {reap: {at: "2026-01-03T00:00:00Z", by: "plan-archive-merged"}} else . end)'

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]
}

# --- 36-37: path containment, red twins --------------------------------------

@test "36: a row id that climbs out of the plans folder is skipped; the folder it points at survives" {
  mkdir -p "$SANDBOX/.notebook/x" "$PLANS/PLAN-001"
  _write_summary "$SANDBOX/.notebook/x"
  printf 'precious\n' > "$SANDBOX/.notebook/x/precious.txt"
  _seed_merged_row_only 'PLAN-001/../../x'
  # The real usage gate already refuses a slash in the ref; a stub that always
  # answers "recorded" leaves the id check as the only thing between the sweep
  # and the folder.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/.gaia/scripts/usage.sh"

  # Guard can fail: the folder the id would reach exists, is a directory and
  # holds a well-formed SUMMARY.md, so the consolidation, age and usage gates
  # all pass and only the id check keeps it.
  [ -d "$PLANS/PLAN-001/../../x" ]

  run --separate-stderr _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ "$(cat "$SANDBOX/.notebook/x/precious.txt")" = "precious" ]
  [ "$(jq -r '.items[] | select(.kind == "plan") | has("reap")' "$CATALOG")" = "false" ]
}

@test "37: a symlinked plan folder pointing outside the notebook is refused and its target survives" {
  outside="$BATS_TEST_TMPDIR/outside-target"
  mkdir -p "$outside"
  _write_summary "$outside"
  printf 'precious\n' > "$outside/precious.txt"
  seed_close_row "$TELEMETRY" plan:PLAN-002 gaia-plan
  _seed_merged_row_only PLAN-002
  ln -s "$outside" "$PLANS/PLAN-002"

  run --separate-stderr _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -L "$PLANS/PLAN-002" ]
  [ "$(cat "$outside/precious.txt")" = "precious" ]
  [ "$(_row_field PLAN-002 reap)" = "none" ]
}

# --- 38: readiness -----------------------------------------------------------

@test "38: a not-yet-moved repo exits 3 with the move command and removes nothing" {
  rm -rf "$SANDBOX"
  SANDBOX="$(_fixture_repository --legacy)"
  PLANS="$SANDBOX/.notebook/plans"
  CATALOG="$SANDBOX/.notebook/catalog.json"
  TELEMETRY="$SANDBOX/.gaia/local/telemetry"
  mkdir -p "$PLANS"
  _seed_merged_plan PLAN-001
  before="$(_snapshot)"

  run --separate-stderr _archive "$SANDBOX"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$stderr"
  [ "$(_snapshot)" = "$before" ]
  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]
}

# --- 39: the tree selector ---------------------------------------------------

@test "39: run from the real repo root, the sweep acts on the operand's fixture only" {
  _seed_merged_plan PLAN-001
  real_before="$(directory_listing_checksum "$REPO_ROOT/.notebook")"

  run bash -c 'cd "$1" && bash "$2/.gaia/scripts/spec/plan-archive-merged.sh" "$2"' _ "$REPO_ROOT" "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]

  real_after="$(directory_listing_checksum "$REPO_ROOT/.notebook")"
  [ "$real_after" = "$real_before" ]
}
