#!/usr/bin/env bats
# Delete-sweep tests for plan-archive-merged.sh, the plans-side mirror of
# spec-archive-merged.sh (see spec-archive-merged.bats for the shared design
# notes: age gate, consolidation gate, usage-ledger gate).
#
# Fixture via helpers/tmp-notebook-repo.sh: a throwaway git repo that carries
# the notebook library, the usage-gate scripts and an empty catalog, so every
# sweep touches only throwaway fixtures. It is built once in setup_file and
# copied for every case. The usage-ledger gate reads the fixture's own
# usage.jsonl; the happy-path seed adds the gaia-plan close it needs.
#
# By the time a plan reaches this sweep it has already been reduced to
# SUMMARY.md by plan-archive.sh, so the seeded happy-path fixture
# is SUMMARY.md-only (no SPEC.md); the consolidation-gate cases add
# SPEC.md back in to exercise the defensive keep case.
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"

# Builds the throwaway fixture repository the suite acts on.
_fixture_repository() {
  "$THIS_DIRECTORY/helpers/tmp-notebook-repo.sh" "$@"
}

setup_file() {
  SEED_SANDBOX="$(_fixture_repository)"
  export SEED_SANDBOX
}

teardown_file() {
  if [ -n "${SEED_SANDBOX:-}" ]; then
    rm -rf "$SEED_SANDBOX"
  fi
}

setup() {
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  ARCHIVE_SOURCE="$REPO_ROOT/.gaia/scripts/spec/plan-archive-merged.sh"
  [ -x "$ARCHIVE_SOURCE" ]
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  # shellcheck source=helpers/usage-gate.sh
  . "$THIS_DIRECTORY/helpers/usage-gate.sh"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  _reset
}

teardown() {
  if [ -n "${LINKED:-}" ]; then
    rm -rf "$LINKED"
  fi
}

# _reset: replaces the sandbox with a copy of the seeded fixture, so each case
# starts from an empty catalog.
_reset() {
  rm -rf "$SANDBOX"
  cp -R "$SEED_SANDBOX" "$SANDBOX"
  PLANS="$SANDBOX/.notebook/plans"
  CATALOG="$SANDBOX/.notebook/catalog.json"
  TELEMETRY="$SANDBOX/.gaia/local/telemetry"
  mkdir -p "$PLANS"
  # A fixed merged_at ("2026-01-02T00:00:00Z"), so every reap case below needs
  # the age gate collapsed to stay deterministic regardless of wall-clock
  # time. The age-gate cases re-export this per case to exercise the window.
  export GAIA_SPEC_RETENTION_DAYS=0
}

_archive() {
  bash "$SANDBOX/.gaia/scripts/spec/plan-archive-merged.sh" "$@"
}

# _sweep <label> [archive args]: runs the sweep over the sandbox and requires exit 0.
_sweep() {
  local label="$1"
  shift
  run _archive "$SANDBOX" "$@"
  [ "$status" -eq 0 ] || { echo "$label: status $status: $output"; return 1; }
}

# _has <label> <text>: the last run's output holds the text.
_has() {
  grep -qF -- "$2" <<<"$output" || { echo "$1: output lacks '$2': $output"; return 1; }
}

# _lacks <label> <text>: the last run's output does not hold the text.
_lacks() {
  if grep -qF -- "$2" <<<"$output"; then
    echo "$1: output holds '$2'"
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
# catalog row's merged_at, for age-window and fail-closed cases.
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

# _days_ago <days>: portable ISO8601 timestamp that many days in the past, computed with
# jq (never `date -d`/`date -j`), matching spec-archive-merged.bats.
_days_ago() {
  jq -rn --argjson days "$1" '(now - ($days * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# _age_case <label> <merged_at> <retention days> <kept|reaped> [pr_number]: one
# merged plan with the given merged_at ("none" clears it, "days:N" is N days ago,
# anything else is written verbatim), swept under the given retention window.
_age_case() {
  local label="$1" merged_at="$2" retention="$3" expected="$4" pr_number="${5:-}"
  _reset
  _seed_merged_plan PLAN-001
  case "$merged_at" in
    none) _clear_merged_at PLAN-001 ;;
    days:*) _set_merged_at PLAN-001 "$(_days_ago "${merged_at#days:}")" ;;
    *) _set_merged_at PLAN-001 "$merged_at" ;;
  esac
  if [ -n "$pr_number" ]; then
    _set_pr_number PLAN-001 "$pr_number"
  else
    [ "$(_row_field PLAN-001 pr_number)" = "none" ] || { echo "$label: fixture row carries a pr_number"; return 1; }
  fi
  export GAIA_SPEC_RETENTION_DAYS="$retention"
  _sweep "$label" || return 1
  if [ "$expected" = reaped ]; then
    _has "$label" "Deleted 1 merged plan folder(s): PLAN-001" || return 1
    [ ! -e "$PLANS/PLAN-001" ] || { echo "$label: folder survived"; return 1; }
    [ "$(_row_field PLAN-001 status)" = "merged" ] || { echo "$label: status changed"; return 1; }
  else
    _lacks "$label" "Deleted" || return 1
    [ -f "$PLANS/PLAN-001/SUMMARY.md" ] || { echo "$label: folder was deleted"; return 1; }
  fi
}

@test "a merged plan whose run is on the usage ledger is deleted with its stamp kept and a reap record, by the sweep or the single-id form, together with others and idempotently" {
  # The sweep deletes the folder; the row keeps its stamp and gains a reap record.
  _seed_merged_plan PLAN-001
  _sweep "sweep" || return 1
  _has "sweep" "Deleted 1 merged plan folder(s): PLAN-001" || return 1
  [ ! -e "$PLANS/PLAN-001" ] || { echo "sweep: folder survived"; return 1; }
  [ "$(_row_field PLAN-001 status)" = "merged" ] || { echo "sweep: status changed"; return 1; }
  [ "$(_row_field PLAN-001 merged_at)" = "2026-01-02T00:00:00Z" ] || { echo "sweep: merged_at changed"; return 1; }
  [ "$(jq -r '.items[] | select(.id == "PLAN-001") | .reap.by' "$CATALOG")" = "plan-archive-merged" ] || { echo "sweep: reap.by"; return 1; }
  [ "$(jq -r '.items[] | select(.id == "PLAN-001") | .reap.at | test("^[0-9]{4}-")' "$CATALOG")" = "true" ] || { echo "sweep: reap.at"; return 1; }

  # Re-running after deleting is a no-op.
  _sweep "re-run" || return 1
  [ -z "$output" ] || { echo "re-run: output '$output'"; return 1; }

  # The single-id form deletes only the named plan.
  _reset
  _seed_merged_plan PLAN-001
  _seed_merged_plan PLAN-002
  _sweep "single id" PLAN-001 || return 1
  _has "single id" "Deleted 1 merged plan folder(s): PLAN-001" || return 1
  [ ! -e "$PLANS/PLAN-001" ] || { echo "single id: named folder survived"; return 1; }
  [ -d "$PLANS/PLAN-002" ] || { echo "single id: other folder deleted"; return 1; }
  [ "$(_row_field PLAN-002 reap)" = "none" ] || { echo "single id: other row reaped"; return 1; }

  # Two merged folders are deleted together with a combined summary.
  _reset
  _seed_merged_plan PLAN-001
  _seed_merged_plan PLAN-002
  _sweep "two folders" || return 1
  _has "two folders" "Deleted 2 merged plan folder(s): PLAN-001, PLAN-002" || return 1
  [ ! -e "$PLANS/PLAN-001" ] || { echo "two folders: first survived"; return 1; }
  [ ! -e "$PLANS/PLAN-002" ] || { echo "two folders: second survived"; return 1; }

  # A leftover defer cache file beside a reapable plan does not block the reap
  # and is neither read nor purged.
  _reset
  _seed_merged_plan PLAN-001
  mkdir -p "$SANDBOX/.gaia/local/cache/wiki-promote"
  printf '{"branch":"plan-1-x"}\n' > "$SANDBOX/.gaia/local/cache/wiki-promote/PLAN-001.json"
  _sweep "defer cache" || return 1
  _has "defer cache" "Deleted 1 merged plan folder(s): PLAN-001" || return 1
  [ ! -e "$PLANS/PLAN-001" ] || { echo "defer cache: folder survived"; return 1; }
  [ -f "$SANDBOX/.gaia/local/cache/wiki-promote/PLAN-001.json" ] || { echo "defer cache: file purged"; return 1; }

  # No merged rows: no output.
  _reset
  _sweep "no merged rows" || return 1
  [ -z "$output" ] || { echo "no merged rows: output '$output'"; return 1; }
}

# Row-status gate: only a merged row with a folder is a candidate.
# bats test_tags=protected
@test "8: a folder without a merged catalog row is never deleted" {
  # A folder with no merged row stays; the merged one is deleted.
  _seed_merged_plan PLAN-001
  _seed_folder_only PLAN-002
  _sweep "no row" || return 1
  _has "no row" "Deleted 1 merged plan folder(s): PLAN-001" || return 1
  [ ! -e "$PLANS/PLAN-001" ] || { echo "no row: merged folder survived"; return 1; }
  [ -f "$PLANS/PLAN-002/SUMMARY.md" ] || { echo "no row: folder without a row deleted"; return 1; }

  # A merged row with no folder is a no-op.
  _reset
  _seed_merged_row_only PLAN-005
  _sweep "no folder" || return 1
  _lacks "no folder" "Deleted" || return 1
  [ "$(_row_field PLAN-005 reap)" = "none" ] || { echo "no folder: row reaped"; return 1; }

  # A ready row with no merged_at is kept, with or without a pr_number.
  _reset
  _seed_merged_plan PLAN-001
  _clear_merged_at PLAN-001
  _set_status PLAN-001 ready
  _sweep "ready" || return 1
  _lacks "ready" "Deleted" || return 1
  [ -d "$PLANS/PLAN-001" ] || { echo "ready: folder deleted"; return 1; }
  _set_pr_number PLAN-001 2601
  _sweep "ready with pr_number" || return 1
  _lacks "ready with pr_number" "Deleted" || return 1
  [ -d "$PLANS/PLAN-001" ] || { echo "ready with pr_number: folder deleted"; return 1; }

  # A ready row carrying a stale aged merged_at is never a candidate.
  _reset
  _seed_merged_plan PLAN-001
  _set_status PLAN-001 ready
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30
  _sweep "ready with stale merged_at" || return 1
  _lacks "ready with stale merged_at" "Deleted" || return 1
  [ -d "$PLANS/PLAN-001" ] || { echo "ready with stale merged_at: folder deleted"; return 1; }

  # A row that already carries a reap record is skipped even when a folder is present.
  _reset
  _seed_merged_plan PLAN-001
  _patch_catalog '.items |= map(if .id == "PLAN-001" then . + {reap: {at: "2026-01-03T00:00:00Z", by: "plan-archive-merged"}} else . end)'
  _sweep "reaped row" || return 1
  _lacks "reaped row" "Deleted" || return 1
  [ -f "$PLANS/PLAN-001/SUMMARY.md" ] || { echo "reaped row: folder deleted"; return 1; }
}

# bats test_tags=protected
@test "age gate: a merged folder is kept inside the retention window or with a missing or unparseable merged_at, and reaped past it, for confirmed and legacy rows, with or without --close" {
  local kept_message="PLAN-001 within retention window (or merged_at missing/unparseable); kept"

  _age_case "inside the window" days:2 30 kept || return 1
  _has "inside the window" "$kept_message" || return 1
  _age_case "past the window" days:45 30 reaped || return 1
  _age_case "missing merged_at" none 0 kept || return 1
  _has "missing merged_at" "$kept_message" || return 1
  _age_case "unparseable merged_at" "not-a-timestamp" 0 kept || return 1
  _has "unparseable merged_at" "$kept_message" || return 1
  _age_case "unparseable prose merged_at" "last tuesday" 0 kept || return 1
  _age_case "just merged, retention 0" days:0 0 reaped || return 1
  _age_case "old, retention 99999" days:400 99999 kept || return 1
  _age_case "confirmed row inside the window" days:2 30 kept 2601 || return 1
  _age_case "confirmed row past the window" days:45 30 reaped 2601 || return 1

  # A non-numeric retention falls back to 30 days: not zero, not unbounded.
  _reset
  export GAIA_SPEC_RETENTION_DAYS="abc"
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 10)"
  _sweep "non-numeric inside" || return 1
  _lacks "non-numeric inside" "Deleted" || return 1
  [ -d "$PLANS/PLAN-001" ] || { echo "non-numeric inside: folder deleted"; return 1; }
  _seed_merged_plan PLAN-002
  _set_merged_at PLAN-002 "$(_days_ago 45)"
  _sweep "non-numeric past" PLAN-002 || return 1
  _has "non-numeric past" "Deleted 1 merged plan folder(s): PLAN-002" || return 1

  # --close is accepted and ignored: a within-window plan stays kept either way.
  _reset
  _seed_merged_plan PLAN-007
  _set_merged_at PLAN-007 "$(_days_ago 2)"
  _set_pr_number PLAN-007 2601
  export GAIA_SPEC_RETENTION_DAYS=30
  _sweep "without --close" PLAN-007 || return 1
  _lacks "without --close" "Deleted" || return 1
  [ -d "$PLANS/PLAN-007" ] || { echo "without --close: folder deleted"; return 1; }
  _sweep "with --close" PLAN-007 --close || return 1
  _lacks "with --close" "Deleted" || return 1
  [ -d "$PLANS/PLAN-007" ] || { echo "with --close: folder deleted"; return 1; }
}

# bats test_tags=protected
@test "consolidation gate: a folder without a verified SUMMARY.md is kept, --close never bypasses it, and a ran test stage waits for its test close" {
  local kept_message="consolidation never ran; kept PLAN-001"

  # --close does not bypass the gate.
  _seed_merged_plan PLAN-002
  rm -f "$PLANS/PLAN-002/SUMMARY.md"
  printf '# Spec\n' > "$PLANS/PLAN-002/SPEC.md"
  _sweep "--close" PLAN-002 --close || return 1
  _lacks "--close" "Deleted" || return 1
  [ -d "$PLANS/PLAN-002" ] || { echo "--close: folder deleted"; return 1; }

  # SPEC.md with no SUMMARY.md is kept past the window even when its run is recorded.
  _reset
  _seed_merged_plan PLAN-001
  rm -f "$PLANS/PLAN-001/SUMMARY.md"
  printf '# Spec\n' > "$PLANS/PLAN-001/SPEC.md"
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30
  _sweep "SPEC.md only" || return 1
  _lacks "SPEC.md only" "Deleted" || return 1
  _has "SPEC.md only" "$kept_message" || return 1
  [ -f "$PLANS/PLAN-001/SPEC.md" ] || { echo "SPEC.md only: folder deleted"; return 1; }

  # summary-verify.sh is the delegate: a non-empty but malformed SUMMARY.md is
  # kept, which a plain non-empty check would wrongly pass.
  _reset
  [ -f "$REPO_ROOT/.gaia/scripts/summary-verify.sh" ] || { echo "summary-verify.sh missing"; return 1; }
  cp "$REPO_ROOT/.gaia/scripts/summary-verify.sh" "$SANDBOX/.gaia/scripts/summary-verify.sh"
  _seed_merged_plan PLAN-001
  printf '# Spec\n' > "$PLANS/PLAN-001/SPEC.md"
  printf 'not frontmatter, not well-formed\n' > "$PLANS/PLAN-001/SUMMARY.md"
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30
  _sweep "malformed SUMMARY.md" || return 1
  _lacks "malformed SUMMARY.md" "Deleted" || return 1
  _has "malformed SUMMARY.md" "$kept_message" || return 1

  # PROGRESS.md with no SUMMARY.md is kept; with a verified SUMMARY.md it is reaped.
  _reset
  cp "$REPO_ROOT/.gaia/scripts/summary-verify.sh" "$SANDBOX/.gaia/scripts/summary-verify.sh"
  _seed_merged_plan PLAN-001
  _set_pr_number PLAN-001 2601
  summary_text="$(cat "$PLANS/PLAN-001/SUMMARY.md")"
  rm -f "$PLANS/PLAN-001/SUMMARY.md"
  printf '## Phase 1\n' > "$PLANS/PLAN-001/PROGRESS.md"
  _sweep "PROGRESS.md only" || return 1
  _lacks "PROGRESS.md only" "Deleted" || return 1
  _has "PROGRESS.md only" "$kept_message" || return 1
  [ -f "$PLANS/PLAN-001/PROGRESS.md" ] || { echo "PROGRESS.md only: folder deleted"; return 1; }
  printf '%s\n' "$summary_text" > "$PLANS/PLAN-001/SUMMARY.md"
  _sweep "PROGRESS.md with SUMMARY.md" || return 1
  _has "PROGRESS.md with SUMMARY.md" "Deleted 1 merged plan folder(s): PLAN-001" || return 1
  [ ! -e "$PLANS/PLAN-001" ] || { echo "PROGRESS.md with SUMMARY.md: folder survived"; return 1; }

  # Only plan files and no SUMMARY.md is kept.
  _reset
  _seed_merged_plan PLAN-001
  rm -f "$PLANS/PLAN-001/SUMMARY.md"
  printf '# Plan\n' > "$PLANS/PLAN-001/PLAN.md"
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30
  _sweep "plan files only" || return 1
  _lacks "plan files only" "Deleted" || return 1
  _has "plan files only" "$kept_message" || return 1
  [ -f "$PLANS/PLAN-001/PLAN.md" ] || { echo "plan files only: folder deleted"; return 1; }

  # A ran test stage keeps the folder until the test close is recorded.
  _reset
  _seed_merged_plan PLAN-001
  printf 'status: ran\ndate: 2026-01-01T00:00:00Z\n' > "$PLANS/PLAN-001/TEST-STAGE"
  _sweep "ran test stage" || return 1
  _lacks "ran test stage" "Deleted" || return 1
  _has "ran test stage" "no gaia-test run recorded for plan:PLAN-001; outside a live gaia-test run, record it: bash .gaia/scripts/usage.sh record plan:PLAN-001 --workflow gaia-test --start <iso>" || return 1
  [ -d "$PLANS/PLAN-001" ] || { echo "ran test stage: folder deleted"; return 1; }
  seed_close_row "$TELEMETRY" plan:PLAN-001 gaia-test
  _sweep "test close recorded" || return 1
  _has "test close recorded" "Deleted 1 merged plan folder(s): PLAN-001" || return 1
  [ ! -e "$PLANS/PLAN-001" ] || { echo "test close recorded: folder survived"; return 1; }
}

# bats test_tags=protected
@test "usage-ledger gate: a plan is reaped only when the usage ledger holds its gaia-plan close" {
  # Without ledger-lib.sh the sweep reaps nothing and says so; with it the same folder is reaped.
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30
  mv "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh" "$SANDBOX/ledger-lib.sh.aside"
  run --separate-stderr _archive "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "no ledger-lib: status $status"; return 1; }
  grep -qF "ledger-lib.sh is unusable; nothing swept" <<<"$stderr" || { echo "no ledger-lib: stderr '$stderr'"; return 1; }
  [ -f "$PLANS/PLAN-001/SUMMARY.md" ] || { echo "no ledger-lib: folder deleted"; return 1; }
  mv "$SANDBOX/ledger-lib.sh.aside" "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh"
  _sweep "ledger-lib restored" || return 1
  [ ! -e "$PLANS/PLAN-001" ] || { echo "ledger-lib restored: folder survived"; return 1; }

  # A run missing from the ledger leaves its folder and the sweep still reaps the next row.
  _reset
  _seed_merged_plan PLAN-001 unrecorded
  _seed_merged_plan PLAN-002
  _sweep "missing run" || return 1
  _has "missing run" "Kept .notebook/plans/PLAN-001: no gaia-plan run recorded for plan:PLAN-001; outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record plan:PLAN-001 --workflow gaia-plan --start <iso>" || return 1
  [ -d "$PLANS/PLAN-001" ] || { echo "missing run: folder deleted"; return 1; }
  [ ! -e "$PLANS/PLAN-002" ] || { echo "missing run: next row survived"; return 1; }

  # A missing ledger keeps the folder and the keep line names the ledger path.
  _reset
  _seed_merged_plan PLAN-001
  rm -f "$TELEMETRY/usage.jsonl"
  _sweep "missing ledger" || return 1
  _lacks "missing ledger" "Deleted" || return 1
  _has "missing ledger" "Kept .notebook/plans/PLAN-001: usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for plan:PLAN-001; once it reads, outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record plan:PLAN-001 --workflow gaia-plan --start <iso>" || return 1
  [ -d "$PLANS/PLAN-001" ] || { echo "missing ledger: folder deleted"; return 1; }

  # A gaia-spec close for the same number does not clear a plan folder.
  _reset
  _seed_merged_plan PLAN-001 unrecorded
  seed_close_row "$TELEMETRY" plan:PLAN-001 gaia-spec
  _sweep "spec close" || return 1
  _lacks "spec close" "Deleted" || return 1
  _has "spec close" "no gaia-plan run recorded for plan:PLAN-001" || return 1
  [ -d "$PLANS/PLAN-001" ] || { echo "spec close: folder deleted"; return 1; }
}

@test "the sweep deletes from the main notebook, run from the main checkout or a linked worktree, and leaves a same-named old-location folder untouched" {
  local fixture

  _seed_merged_plan PLAN-003
  _set_pr_number PLAN-003 2601
  mkdir -p "$SANDBOX/.gaia/local/plans/PLAN-003"
  printf 'decoy\n' > "$SANDBOX/.gaia/local/plans/PLAN-003/SUMMARY.md"
  _sweep "main checkout" || return 1
  _has "main checkout" "Deleted 1 merged plan folder(s): PLAN-003" || return 1
  [ ! -e "$PLANS/PLAN-003" ] || { echo "main checkout: folder survived"; return 1; }
  [ "$(cat "$SANDBOX/.gaia/local/plans/PLAN-003/SUMMARY.md")" = "decoy" ] || { echo "main checkout: old-location folder touched"; return 1; }
  [ "$(_row_field PLAN-003 reap | head -c 1)" = "{" ] || { echo "main checkout: no reap record"; return 1; }

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
  [ "$status" -eq 0 ] || { echo "linked worktree: status $status"; return 1; }
  _has "linked worktree" "Deleted 1 merged plan folder(s): PLAN-003" || return 1
  [ ! -e "$PLANS/PLAN-003" ] || { echo "linked worktree: folder survived"; return 1; }
  [ "$(cat "$SANDBOX/.gaia/local/plans/PLAN-003/SUMMARY.md")" = "decoy" ] || { echo "linked worktree: old-location folder touched"; return 1; }
  [ "$(jq -r '.items[] | select(.id == "PLAN-003") | .reap.by' "$CATALOG")" = "plan-archive-merged" ] || { echo "linked worktree: reap.by"; return 1; }
  [ -L "$LINKED/.notebook" ] || { echo "linked worktree: .notebook is not a link"; return 1; }
}

# bats test_tags=protected
@test "path escape: a row id that climbs out of the plans folder is skipped and a symlinked plan folder is refused, leaving the targets intact" {
  local outside

  mkdir -p "$SANDBOX/.notebook/x" "$PLANS/PLAN-001"
  _write_summary "$SANDBOX/.notebook/x"
  printf 'precious\n' > "$SANDBOX/.notebook/x/precious.txt"
  _seed_merged_row_only 'PLAN-001/../../x'
  # The real usage gate already refuses a slash in the ref; a stub that always
  # answers "recorded" leaves the id check as the only thing between the sweep
  # and the folder.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/.gaia/scripts/usage.sh"
  # The folder the id would reach exists, is a directory and holds a
  # well-formed SUMMARY.md, so the consolidation, age and usage gates all pass
  # and only the id check keeps it.
  [ -d "$PLANS/PLAN-001/../../x" ] || { echo "climbing id: fixture folder missing"; return 1; }
  run --separate-stderr _archive "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "climbing id: status $status"; return 1; }
  _lacks "climbing id" "Deleted" || return 1
  [ "$(cat "$SANDBOX/.notebook/x/precious.txt")" = "precious" ] || { echo "climbing id: target lost"; return 1; }
  [ "$(jq -r '.items[] | select(.kind == "plan") | has("reap")' "$CATALOG")" = "false" ] || { echo "climbing id: row reaped"; return 1; }

  _reset
  outside="$BATS_TEST_TMPDIR/outside-target"
  mkdir -p "$outside"
  _write_summary "$outside"
  printf 'precious\n' > "$outside/precious.txt"
  seed_close_row "$TELEMETRY" plan:PLAN-002 gaia-plan
  _seed_merged_row_only PLAN-002
  ln -s "$outside" "$PLANS/PLAN-002"
  run --separate-stderr _archive "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "symlinked folder: status $status"; return 1; }
  _lacks "symlinked folder" "Deleted" || return 1
  [ -L "$PLANS/PLAN-002" ] || { echo "symlinked folder: link removed"; return 1; }
  [ "$(cat "$outside/precious.txt")" = "precious" ] || { echo "symlinked folder: target lost"; return 1; }
  [ "$(_row_field PLAN-002 reap)" = "none" ] || { echo "symlinked folder: row reaped"; return 1; }
}

@test "39: run from the real repo root, the sweep acts on the operand's fixture only" {
  _seed_merged_plan PLAN-001
  real_before="$(directory_listing_checksum "$REPO_ROOT/.notebook")"

  run bash -c 'cd "$1" && bash "$2/.gaia/scripts/spec/plan-archive-merged.sh" "$2"' _ "$REPO_ROOT" "$SANDBOX"
  [ "$status" -eq 0 ]
  _has "real root" "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]

  real_after="$(directory_listing_checksum "$REPO_ROOT/.notebook")"
  [ "$real_after" = "$real_before" ]
}
