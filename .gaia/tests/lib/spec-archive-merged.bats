#!/usr/bin/env bats
# Delete-sweep tests for spec-archive-merged.sh.
#
# The sweep is the safety net for the post-merge close: a merged SPEC whose
# folder still sits in the notebook's specs folder (PR merged out-of-band, or
# an orchestrator that ended before its close) gets deleted by the pre-flight
# sweep of the next /gaia-spec or /gaia-plan run, once the retention window
# has passed. There is no early reap: --close is accepted and ignored.
#
# Deletion is gated on the usage ledger (`usage.sh represented`): a folder is
# only deleted once the ledger holds a gaia-spec close for its spec ref, and a
# gaia-plan close too when it holds a plan or plan-<N> subfolder.
# tmp-notebook-repo.sh seeds an empty .gaia/local/telemetry/usage.jsonl and
# copies usage.sh with its libraries into every tmp repo so the gate resolves
# in isolation; tests append close rows with seed_close_row. A folder whose run
# the ledger does not record is kept and one stdout keep line names the ref and
# the recovery command.
#
# Sweep criteria: a catalog row with status "merged" and no reap record AND a
# folder AND an aged merged_at AND a passing usage-ledger gate. A merged row
# with no folder is skipped; a gate failure leaves the folder in place. A
# successful delete records a reap on the row.
#
# Each test spins up its own tmp git repo via helpers/tmp-notebook-repo.sh, or
# copies the one setup_file seeds, and tears it down; hermetic, no reliance on
# the real project notebook. The teardown uses the explicit-if form (the &&
# idiom is a bats teardown footgun: a falsy first clause makes teardown itself "fail").
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  ARCHIVE=".gaia/scripts/spec/spec-archive-merged.sh"
  SPECS=".notebook/specs"
  USAGE_LEDGER=".gaia/local/telemetry/usage.jsonl"
  # shellcheck source=helpers/usage-gate.sh
  . "$HELPERS/usage-gate.sh"
  # --seed-spec-merged-folder stamps a fixed merged_at ("2026-01-01T00:00:00Z")
  # rather than "just merged", so every delete test below needs the age gate
  # collapsed to stay deterministic regardless of wall-clock time. The
  # age-gate tests re-export this per test to exercise the window itself.
  export GAIA_SPEC_RETENTION_DAYS=0
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

_archive() {
  bash "$REPO/$ARCHIVE" "$@"
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

# Deterministic snapshot of the specs tree: relative paths + per-file sha,
# sorted. Used to assert "nothing changed" across idempotent / skip runs.
_snapshot() {
  ( cd "$REPO/$SPECS" 2>/dev/null \
      && find . -type f -print0 2>/dev/null \
         | sort -z \
         | xargs -0 shasum 2>/dev/null ) || true
}

# _seed_close <ref> <workflow>: appends the close binding row (the shape
# `usage.sh record` writes) that `usage.sh represented` looks for, so the
# usage-ledger gate finds the run.
_seed_close() {
  seed_close_row "$REPO/.gaia/local/telemetry" "$1" "$2"
}

# _days_ago <days>: portable ISO8601 timestamp that many days in the past, computed with
# jq (never `date -d`/`date -j`, matching the project's cross-platform epoch
# rule; mirrors spec-abandon-empty.bats's old_ts/new_ts helpers).
_days_ago() {
  jq -rn --argjson days "$1" '(now - ($days * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# _set_merged_at <repo> <spec_id> <iso>: patches the seeded ledger row's
# merged_at, for tests that need a specific age instead of the fixture's
# fixed date.
_set_merged_at() {
  local repo="$1" id="$2" iso="$3"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" --arg timestamp "$iso" \
    '.items |= map(if .kind == "spec" and .id == $id then . + {merged_at: $timestamp} else . end)' \
    "$repo/.notebook/catalog.json" > "$temporary_file"
  mv "$temporary_file" "$repo/.notebook/catalog.json"
}

# _clear_merged_at <repo> <spec_id>: removes merged_at from the seeded ledger
# row, for the missing-merged_at keep case.
_clear_merged_at() {
  local repo="$1" id="$2"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" \
    '.items |= map(if .kind == "spec" and .id == $id then del(.merged_at) else . end)' \
    "$repo/.notebook/catalog.json" > "$temporary_file"
  mv "$temporary_file" "$repo/.notebook/catalog.json"
}

# The case tables copy one seeded repo (a merged SPEC-001 folder, no close
# recorded) per case instead of building a repo per case.
setup_file() {
  BASE="$("$BATS_TEST_DIRNAME/helpers/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001)"
  export BASE
}

teardown_file() {
  if [ -n "${BASE:-}" ]; then
    rm -rf "$BASE"
  fi
}

# _fresh_case: points REPO at a fresh copy of the seeded repo.
_fresh_case() {
  rm -rf "$REPO"
  REPO="$BATS_TEST_TMPDIR/case"
  cp -R "$BASE" "$REPO"
}

# --- 1: delete happy path (cost represented) ---------------------------------

@test "1: a merged row whose run is on the usage ledger is deleted; ledger stays merged" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001)"
  _seed_close spec:SPEC-001 gaia-spec

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/archived" ]

  # Row kept: still merged, merged_at unchanged (the stamp is a precondition,
  # not set by this sweep), and a reap record names this script.
  [ "$(jq -r '.items[0].status' "$REPO/.notebook/catalog.json")" = "merged" ]
  [ "$(jq -r '.items[0].merged_at' "$REPO/.notebook/catalog.json")" = "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.items[0].reap.by' "$REPO/.notebook/catalog.json")" = "spec-archive-merged.sh" ]
  jq -e '.items[0].reap.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$REPO/.notebook/catalog.json"
}

# --- row selection ------------------------------------------------------------

# bats test_tags=protected
@test "merged sweep touches only merged rows with a folder and no reap record" {
  # One repo holds every selection case: SPEC-001 is the only reapable row.
  # SPEC-004 already carries a reap record, SPEC-005 has no folder and
  # SPEC-002 is a folder with no merged row.
  REPO="$("$HELPERS/tmp-notebook-repo.sh" \
    --seed-spec-merged-folder SPEC-001 --seed-spec-merged-folder SPEC-004 \
    --seed-spec SPEC-005 merged --seed-spec-folder SPEC-002 draft)"
  _seed_close spec:SPEC-001 gaia-spec
  _seed_close spec:SPEC-004 gaia-spec
  patched="$(mktemp)"
  jq '.items |= map(if .id == "SPEC-004" then . + {reap: {at: "2026-02-01T00:00:00Z", by: "spec-archive-merged.sh"}} else . end)' \
    "$REPO/.notebook/catalog.json" > "$patched"
  mv "$patched" "$REPO/.notebook/catalog.json"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  grep -qxF "Deleted 1 merged SPEC folder(s): SPEC-001" <<<"$output"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  echo "case: a row with a reap record is skipped"
  [ -f "$REPO/$SPECS/SPEC-004/SPEC.md" ]
  echo "case: a merged row with no active folder is a no-op"
  [ ! -e "$REPO/$SPECS/archived" ]
  echo "case: a folder without a merged row is never deleted"
  [ -f "$REPO/$SPECS/SPEC-002/SPEC.md" ]

  echo "case: re-running the sweep after deleting is a no-op"
  before="$(_snapshot)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  after="$(_snapshot)"
  [ "$before" = "$after" ]

  echo "case: a repo with no merged rows produces no output and exits 0"
  rm -rf "$REPO"
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- both entry points delete, neither leaves an archived/ copy ---------------

# bats test_tags=protected
@test "all-ids sweep deletes with a combined summary and the single-id form deletes only the named id" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001 --seed-spec-merged-folder SPEC-002)"
  _seed_close spec:SPEC-001 gaia-spec
  _seed_close spec:SPEC-002 gaia-spec

  echo "case: the all-ids sweep deletes both with a combined summary"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 2 merged SPEC folder(s): SPEC-001, SPEC-002"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/SPEC-002" ]
  [ ! -e "$REPO/$SPECS/archived" ]

  echo "case: the single-id form deletes only the named id"
  REPO2="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-003 --seed-spec-merged-folder SPEC-004)"
  seed_close_row "$REPO2/.gaia/local/telemetry" spec:SPEC-003 gaia-spec
  seed_close_row "$REPO2/.gaia/local/telemetry" spec:SPEC-004 gaia-spec
  run bash "$REPO2/$ARCHIVE" "$REPO2" SPEC-003
  [ "$status" -eq 0 ]
  [ ! -e "$REPO2/$SPECS/SPEC-003" ]
  [ -d "$REPO2/$SPECS/SPEC-004" ]
  [ ! -e "$REPO2/$SPECS/archived" ]
  rm -rf "$REPO2"
}

# --- a leftover defer cache does not block a reap -----------------------------

# bats test_tags=protected
@test "6: a leftover wiki-promote defer cache file beside a reapable spec no longer blocks its reap" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001)"
  _seed_close spec:SPEC-001 gaia-spec
  mkdir -p "$REPO/.gaia/local/cache/wiki-promote"
  printf '{"branch":"spec-1-x"}\n' > "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  # The sweep neither reads nor purges the retired path.
  [ -f "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json" ]
}

# --- the retention window and the merged_at rule ------------------------------

# bats test_tags=protected
@test "merged sweep retention window and merged_at rule" {
  # Columns: label, GAIA_SPEC_RETENTION_DAYS, merged_at (days:<n> ago, none to
  # drop it, or a raw value), whether the gaia-spec close is recorded, outcome,
  # whether the keep line is asserted, and whether a second run with --close
  # must also keep the folder (--close is accepted and ignored: no early reap).
  local label retention stamp recorded outcome keep_line with_close
  while IFS='|' read -r label retention stamp recorded outcome keep_line with_close; do
    echo "case: $label"
    _fresh_case
    case "$stamp" in
      none) _clear_merged_at "$REPO" SPEC-001 ;;
      days:*) _set_merged_at "$REPO" SPEC-001 "$(_days_ago "${stamp#days:}")" ;;
      *) _set_merged_at "$REPO" SPEC-001 "$stamp" ;;
    esac
    if [ "$recorded" = yes ]; then _seed_close spec:SPEC-001 gaia-spec; fi
    export GAIA_SPEC_RETENTION_DAYS="$retention"

    run _archive "$REPO"
    [ "$status" -eq 0 ]
    if [ "$outcome" = reaped ]; then
      assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"
      [ ! -e "$REPO/$SPECS/SPEC-001" ]
      # The row stays merged; merged_at is a precondition, not set by the sweep.
      [ "$(jq -r '.items[0].status' "$REPO/.notebook/catalog.json")" = "merged" ]
    else
      refute_contains "Deleted"
      [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
      if [ "$keep_line" = yes ]; then
        assert_contains "SPEC-001 within retention window (or merged_at missing/unparseable); kept"
      fi
    fi
    if [ "$with_close" = yes ]; then
      run bash "$REPO/$ARCHIVE" "$REPO" SPEC-001 --close
      [ "$status" -eq 0 ]
      refute_contains "Deleted"
      [ -d "$REPO/$SPECS/SPEC-001" ]
    fi
  done <<'CASES'
within the retention window is kept|30|days:2|no|kept|yes|no
past the retention window with its run recorded is reaped|30|days:45|yes|reaped|no|no
no merged_at is kept regardless of representation|0|none|no|kept|yes|no
an unparseable merged_at is kept regardless of representation|0|not-a-timestamp|no|kept|yes|no
GAIA_SPEC_RETENTION_DAYS=0 reaps a just-merged recorded folder|0|days:0|yes|reaped|no|no
GAIA_SPEC_RETENTION_DAYS=99999 keeps an old merged folder|99999|days:400|no|kept|no|no
a non-numeric GAIA_SPEC_RETENTION_DAYS keeps a 10-day-old folder under the 30-day default|abc|days:10|no|kept|no|no
a non-numeric GAIA_SPEC_RETENTION_DAYS reaps a 45-day-old recorded folder under the 30-day default|abc|days:45|yes|reaped|no|no
a within-window consolidated folder stays kept with and without --close|30|days:2|no|kept|no|yes
CASES
}

# --- the consolidation gate ---------------------------------------------------

_consolidation_close_does_not_bypass() {
  rm -f "$REPO/$SPECS/SPEC-001/SUMMARY.md"

  run bash "$REPO/$ARCHIVE" "$REPO" SPEC-001 --close
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$REPO/$SPECS/SPEC-001" ]
}

_consolidation_spec_without_summary_kept() {
  rm -f "$REPO/$SPECS/SPEC-001/SUMMARY.md"
  _seed_close spec:SPEC-001 gaia-spec
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept SPEC-001"
  [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
}

_consolidation_audit_only_kept() {
  rm -f "$REPO/$SPECS/SPEC-001/SPEC.md" "$REPO/$SPECS/SPEC-001/SUMMARY.md"
  printf '# Audit\n' > "$REPO/$SPECS/SPEC-001/AUDIT.md"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept SPEC-001"
  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}

_consolidation_summary_only_passes() {
  _seed_close spec:SPEC-001 gaia-spec
  rm -f "$REPO/$SPECS/SPEC-001/SPEC.md"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

_consolidation_malformed_summary_kept() {
  local real_root verify_source
  real_root="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --show-toplevel)"
  verify_source="$real_root/.gaia/scripts/summary-verify.sh"
  [ -f "$verify_source" ]
  cp "$verify_source" "$REPO/.gaia/scripts/summary-verify.sh"
  # SPEC.md is already seeded; overwrite SUMMARY.md with non-empty but
  # malformed content (no frontmatter/H1). A plain [ -s SUMMARY.md ] fallback
  # would wrongly pass this; only real delegation to summary-verify.sh
  # catches the malformed shape.
  printf 'not frontmatter, not well-formed\n' > "$REPO/$SPECS/SPEC-001/SUMMARY.md"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept SPEC-001"
}

# bats test_tags=protected
@test "consolidation gate keeps unconsolidated folders and --close does not bypass it" {
  local label function_name
  while IFS='|' read -r label function_name; do
    echo "case: $label"
    _fresh_case
    export GAIA_SPEC_RETENTION_DAYS=0
    "$function_name"
  done <<'CASES'
--close does not bypass the consolidation gate|_consolidation_close_does_not_bypass
a folder holding SPEC.md with no SUMMARY.md is kept past the window even when its run is recorded|_consolidation_spec_without_summary_kept
a folder holding only AUDIT.md (no SPEC.md, no SUMMARY.md) is kept|_consolidation_audit_only_kept
a folder already reduced to SUMMARY.md (no SPEC.md) passes the consolidation gate|_consolidation_summary_only_passes
prefers summary-verify.sh when present; a malformed but non-empty SUMMARY.md is kept|_consolidation_malformed_summary_kept
CASES
}

# --- the liveness lock is reaped with the rest of the merged keyset -----------

@test "27: a .lock file is reaped alongside the deleted merged folder" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001)"
  _seed_close spec:SPEC-001 gaia-spec
  echo '{"spec_id":"SPEC-001"}' > "$REPO/.gaia/local/cache/spec-session-SPEC-001.lock"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/.gaia/local/cache/spec-session-SPEC-001.lock" ]
}

# bats test_tags=protected
@test "28: without ledger-lib.sh the sweep reaps nothing and says so; with it the same folder is reaped" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001)"
  _seed_close spec:SPEC-001 gaia-spec

  mv "$REPO/.gaia/scripts/spec/ledger-lib.sh" "$REPO/ledger-lib.sh.aside"
  run --separate-stderr _archive "$REPO"
  [ "$status" -eq 0 ]
  grep -qF "ledger-lib.sh is unusable; nothing swept" <<<"$stderr"
  [ -d "$REPO/$SPECS/SPEC-001" ]

  mv "$REPO/ledger-lib.sh.aside" "$REPO/.gaia/scripts/spec/ledger-lib.sh"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

# --- the usage-ledger gate over folder shapes ---------------------------------

_close_gate_missing_run() {
  # This case needs a second reapable row, so it builds its own repo.
  rm -rf "$REPO"
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001 --seed-spec-merged-folder SPEC-002)"
  _seed_close spec:SPEC-002 gaia-spec

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Kept specs/SPEC-001: no gaia-spec run recorded for spec:SPEC-001; outside a live gaia-spec run, record it: bash .gaia/scripts/usage.sh record spec:SPEC-001 --workflow gaia-spec --start <iso>"
  [ -d "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/SPEC-002" ]
}

_close_gate_missing_ledger() {
  rm -f "$REPO/$USAGE_LEDGER"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "Kept specs/SPEC-001: usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for spec:SPEC-001; once it reads, outside a live gaia-spec run, record it: bash .gaia/scripts/usage.sh record spec:SPEC-001 --workflow gaia-spec --start <iso>"
  [ -d "$REPO/$SPECS/SPEC-001" ]
}

_close_gate_plan_close_alone() {
  _seed_close spec:SPEC-001 gaia-plan

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "Kept specs/SPEC-001: no gaia-spec run recorded for spec:SPEC-001"
  [ -d "$REPO/$SPECS/SPEC-001" ]
}

_close_gate_plan_subfolder() {
  mkdir -p "$REPO/$SPECS/SPEC-001/plan"
  _seed_close spec:SPEC-001 gaia-spec

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "Kept specs/SPEC-001: no gaia-plan run recorded for spec:SPEC-001; outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record spec:SPEC-001 --workflow gaia-plan --start <iso>"
  [ -d "$REPO/$SPECS/SPEC-001/plan" ]

  _seed_close spec:SPEC-001 gaia-plan
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

_close_gate_numbered_plan_subfolder() {
  mkdir -p "$REPO/$SPECS/SPEC-001/plan-2"
  _seed_close spec:SPEC-001 gaia-spec

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "no gaia-plan run recorded for spec:SPEC-001"
  [ -d "$REPO/$SPECS/SPEC-001/plan-2" ]
}

_close_gate_test_stage_ran() {
  mkdir -p "$REPO/$SPECS/SPEC-001/plan"
  printf 'status: ran\ndate: 2026-01-01T00:00:00Z\n' > "$REPO/$SPECS/SPEC-001/plan/TEST-STAGE"
  _seed_close spec:SPEC-001 gaia-spec
  _seed_close spec:SPEC-001 gaia-plan

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "Kept specs/SPEC-001: no gaia-test run recorded for spec:SPEC-001; outside a live gaia-test run, record it: bash .gaia/scripts/usage.sh record spec:SPEC-001 --workflow gaia-test --start <iso>"
  [ -d "$REPO/$SPECS/SPEC-001/plan" ]

  _seed_close spec:SPEC-001 gaia-test
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

_close_gate_test_stage_skipped() {
  mkdir -p "$REPO/$SPECS/SPEC-001/plan"
  printf 'status: skipped\n' > "$REPO/$SPECS/SPEC-001/plan/TEST-STAGE"
  _seed_close spec:SPEC-001 gaia-spec
  _seed_close spec:SPEC-001 gaia-plan

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"
}

# bats test_tags=protected
@test "deletion requires the close records the folder shape owes" {
  local label function_name
  while IFS='|' read -r label function_name; do
    echo "case: $label"
    _fresh_case
    "$function_name"
  done <<'CASES'
a run missing from the usage ledger leaves its folder, prints the keep line, and the sweep still reaps the next row|_close_gate_missing_run
a missing usage ledger keeps the folder and the keep line names the ledger path|_close_gate_missing_ledger
a gaia-plan close alone does not clear a folder that needs its gaia-spec run|_close_gate_plan_close_alone
a folder holding a plan subfolder needs both the gaia-spec and the gaia-plan close|_close_gate_plan_subfolder
a plan-<N> subfolder also requires the gaia-plan close|_close_gate_numbered_plan_subfolder
a plan subfolder whose TEST-STAGE ran also needs the gaia-test close|_close_gate_test_stage_ran
a skipped TEST-STAGE owes no gaia-test close|_close_gate_test_stage_skipped
CASES
}
