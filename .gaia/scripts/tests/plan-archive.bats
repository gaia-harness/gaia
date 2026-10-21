#!/usr/bin/env bats
# Tests for `.gaia/scripts/plan-archive.sh`.
#
# Each test runs the script inside an isolated git sandbox built by
# helpers/tmp-notebook-repo.sh, so its repo-root lookup resolves to the fixture
# root (not the GAIA repo root) and every reduce/delete touches only throwaway
# fixtures. The sandbox's own main checkout similarly resolves the usage-ledger
# gate to the sandbox's own .gaia/local/telemetry/usage.jsonl, never the real
# repo's. The notebook library classifies the argument, so plan folders live in
# the sandbox's notebook, not under the old local roots.
#
# The gate is `usage.sh represented`: a plan folder is reduced or deleted only
# when the usage ledger holds the close it needs, and is kept (with one stdout
# keep line naming the recovery command) when it does not.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# Builds the throwaway fixture repository the suite acts on.
_fixture_repository() {
  "$TMP_NOTEBOOK_REPO" "$@"
}

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIRECTORY/../plan-archive.sh"
  [ -x "$SCRIPT" ]
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  # copy_usage_gate + seed_close_row.
  . "$REPO_ROOT/.gaia/tests/lib/helpers/usage-gate.sh"
  TMP_NOTEBOOK_REPO="$REPO_ROOT/.gaia/tests/lib/helpers/tmp-notebook-repo.sh"

  SANDBOX="$(_fixture_repository)"
  # The fixture carries summary-verify.sh; the cases that exercise the plain
  # non-empty fallback need it absent, and copy_summary_verify puts it back.
  rm -f "$SANDBOX/.gaia/scripts/summary-verify.sh"
  CATALOG="$SANDBOX/.notebook/catalog.json"
  TELEMETRY="$SANDBOX/.gaia/local/telemetry"
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    rm -rf "$SANDBOX"
  fi
  if [ -n "${LINKED:-}" ]; then
    rm -rf "$LINKED"
  fi
}

run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" "$@" )
}

# copy_summary_verify: mirrors plan-archive.sh's own .gaia/scripts/
# summary-verify.sh call target inside the sandbox, so the spec-colocated
# consolidation gate delegates to the real verify-gate instead of falling
# back to a plain non-empty check. Tests that don't call this exercise the
# fallback path (summary-verify.sh absent from the sandbox).
copy_summary_verify() {
  cp "$REPO_ROOT/.gaia/scripts/summary-verify.sh" "$SANDBOX/.gaia/scripts/summary-verify.sh"
}

# seed_plan <relative_directory>: creates a plan folder (relative to $SANDBOX) with the
# canonical fixture set: SUMMARY.md (the consolidated artifact), PROGRESS.md
# (the live run ledger), KICKOFF.md, RUNNING, .work/x. Callers that need the
# gate to pass add a close row afterward with seed_close.
seed_plan() {
  local plan_directory="$SANDBOX/$1"
  mkdir -p "$plan_directory/.work"
  echo "summary" > "$plan_directory/SUMMARY.md"
  echo "progress" > "$plan_directory/PROGRESS.md"
  echo "kickoff" > "$plan_directory/KICKOFF.md"
  : > "$plan_directory/RUNNING"
  echo "scratch" > "$plan_directory/.work/x"
}

# seed_close <ref> <workflow>: appends the close binding row `usage.sh
# record` writes to the sandbox's usage ledger. plan-archive.sh resolves that
# ledger itself from the main checkout (never a flag passed to the script).
seed_close() {
  seed_close_row "$TELEMETRY" "$1" "$2"
}

# assert_deleted <absolute_directory>: the dir (and everything under it) is gone.
assert_deleted() {
  [ ! -e "$1" ]
}

# stub_usage_script: replaces the sandbox's usage.sh with one that logs every
# invocation to $SANDBOX/usage-calls.log and exits 1 (no run recorded).
stub_usage_script() {
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"\$*\" >> \"$SANDBOX/usage-calls.log\""
    echo 'exit 1'
  } > "$SANDBOX/.gaia/scripts/usage.sh"
}

# seed_plan_row <plan_id>: appends a ready catalog row for the plan.
seed_plan_row() {
  local temporary_file
  temporary_file="$(mktemp)"
  jq --arg id "$1" \
    '.items += [{kind: "plan", id: $id, path: ("plans/" + $id), status: "ready", subject: "x", source: "allocated", created_at: "2026-01-01T00:00:00Z", status_changed_at: "2026-01-01T00:00:00Z"}]' \
    "$CATALOG" > "$temporary_file"
  mv "$temporary_file" "$CATALOG"
}

# plan_row_field <plan_id> <field>: reads a field off <plan_id>'s catalog row
# ("null" if absent).
plan_row_field() {
  local id="$1" field="$2"
  jq -r --arg id "$id" --arg field "$field" \
    '.items[] | select(.kind == "plan" and .id == $id) | .[$field] // "null"' \
    "$CATALOG"
}

# listing: every path under the sandbox except git's own store, with file
# contents summed, for a before/after comparison that sees any change.
listing() {
  find "$SANDBOX" -path "$SANDBOX/.git" -prune -o -type f -exec cksum {} + | LC_ALL=C sort
  find "$SANDBOX" -path "$SANDBOX/.git" -prune -o -print | LC_ALL=C sort
}

# --- 1. Spec-less PLAN-NNN reduce, catalog row stamped merged ---------------

@test "spec-less PLAN-NNN: recorded run -> reduced to SUMMARY.md alone, RUNNING/PROGRESS.md gone, row stamped merged" {
  seed_plan ".notebook/plans/PLAN-005"
  seed_close plan:PLAN-005 gaia-plan
  seed_plan_row PLAN-005
  run run_in_sandbox ".notebook/plans/PLAN-005"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.notebook/plans/PLAN-005" ]
  [ -f "$SANDBOX/.notebook/plans/PLAN-005/SUMMARY.md" ]
  [ ! -e "$SANDBOX/.notebook/plans/PLAN-005/RUNNING" ]
  [ ! -e "$SANDBOX/.notebook/plans/PLAN-005/PROGRESS.md" ]
  [ ! -e "$SANDBOX/.notebook/plans/PLAN-005/KICKOFF.md" ]
  [ "$(find "$SANDBOX/.notebook/plans/PLAN-005" -mindepth 1 | wc -l | tr -d ' ')" = "1" ]
  [ "$(plan_row_field PLAN-005 status)" = "merged" ]
  [ -n "$(plan_row_field PLAN-005 merged_at)" ]
  grep -qF "Reduced plan folder to SUMMARY.md (kept for age-reap)" <<<"$output"
}

@test "spec-less PLAN-NNN reduce removes a legacy sidecar left in the folder" {
  seed_plan ".notebook/plans/PLAN-008"
  # Built from parts: a folder written by an older release holds this file, and
  # the reduce must clear it with everything else.
  echo "{}" > "$SANDBOX/.notebook/plans/PLAN-008/cost"".json"
  seed_close plan:PLAN-008 gaia-plan
  run run_in_sandbox ".notebook/plans/PLAN-008"
  [ "$status" -eq 0 ]
  [ "$(find "$SANDBOX/.notebook/plans/PLAN-008" -mindepth 1 | wc -l | tr -d ' ')" = "1" ]
  [ -f "$SANDBOX/.notebook/plans/PLAN-008/SUMMARY.md" ]
}

# --- 2. Colocated plan delete, parent untouched -----------------------------

@test "colocated plan: parent SPEC SUMMARY.md present + gaia-plan close -> plan/ deleted, parent SPEC folder and SPEC.md untouched" {
  seed_plan ".notebook/specs/SPEC-005/plan"
  echo "spec body" > "$SANDBOX/.notebook/specs/SPEC-005/SPEC.md"
  echo "# SPEC-005" > "$SANDBOX/.notebook/specs/SPEC-005/SUMMARY.md"
  seed_close spec:SPEC-005 gaia-plan
  run run_in_sandbox ".notebook/specs/SPEC-005/plan"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.notebook/specs/SPEC-005/plan"
  [ -d "$SANDBOX/.notebook/specs/SPEC-005" ]
  [ -f "$SANDBOX/.notebook/specs/SPEC-005/SPEC.md" ]
  grep -qF "Deleted plan folder: .notebook/specs/SPEC-005/plan" <<<"$output"
  grep -qF "the usage ledger holds the run record" <<<"$output"
}

# --- 3. Colocated plan-2 revision, same delete semantics --------------------

@test "colocated plan-2 revision: parent SPEC SUMMARY.md present + gaia-plan close -> deleted, parent untouched" {
  seed_plan ".notebook/specs/SPEC-005/plan-2"
  echo "# SPEC-005" > "$SANDBOX/.notebook/specs/SPEC-005/SUMMARY.md"
  seed_close spec:SPEC-005 gaia-plan
  run run_in_sandbox ".notebook/specs/SPEC-005/plan-2"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.notebook/specs/SPEC-005/plan-2"
  grep -qF "Deleted plan folder: .notebook/specs/SPEC-005/plan-2" <<<"$output"
}

@test "colocated plans: one gaia-plan close for the spec ref clears both plan and plan-2" {
  seed_plan ".notebook/specs/SPEC-005/plan"
  seed_plan ".notebook/specs/SPEC-005/plan-2"
  echo "# SPEC-005" > "$SANDBOX/.notebook/specs/SPEC-005/SUMMARY.md"
  seed_close spec:SPEC-005 gaia-plan
  run run_in_sandbox ".notebook/specs/SPEC-005/plan"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.notebook/specs/SPEC-005/plan"
  run run_in_sandbox ".notebook/specs/SPEC-005/plan-2"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.notebook/specs/SPEC-005/plan-2"
}

# --- 3a. Wrong workflow does not clear the gate -----------------------------

@test "colocated plan: only a gaia-spec close for the spec ref -> kept with the gaia-plan keep line" {
  seed_plan ".notebook/specs/SPEC-005/plan"
  echo "# SPEC-005" > "$SANDBOX/.notebook/specs/SPEC-005/SUMMARY.md"
  seed_close spec:SPEC-005 gaia-spec
  run run_in_sandbox ".notebook/specs/SPEC-005/plan"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.notebook/specs/SPEC-005/plan" ]
  [ "$output" = "Kept .notebook/specs/SPEC-005/plan: no gaia-plan run recorded for spec:SPEC-005; outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record spec:SPEC-005 --workflow gaia-plan --start <iso>" ]
}

# --- 3b. Fail-closed consolidation gate: no parent SUMMARY.md -> kept --------

@test "colocated plan: parent SPEC has no consolidated SUMMARY.md yet -> plan/ kept (fail-closed consolidation gate)" {
  seed_plan ".notebook/specs/SPEC-020/plan"
  echo "spec body" > "$SANDBOX/.notebook/specs/SPEC-020/SPEC.md"
  seed_close spec:SPEC-020 gaia-plan
  run run_in_sandbox ".notebook/specs/SPEC-020/plan"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.notebook/specs/SPEC-020/plan" ]
  [ -f "$SANDBOX/.notebook/specs/SPEC-020/plan/PROGRESS.md" ]
  grep -qF "Retained plan" <<<"$output"
}

@test "colocated plan-2: deleted only when the parent SUMMARY.md exists; absent, it is kept" {
  seed_plan ".notebook/specs/SPEC-001/plan-2"
  seed_close spec:SPEC-001 gaia-plan

  run run_in_sandbox ".notebook/specs/SPEC-001/plan-2"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.notebook/specs/SPEC-001/plan-2/PROGRESS.md" ]
  grep -qF "Retained plan (parent SPEC not yet consolidated)" <<<"$output"

  echo "# SPEC-001" > "$SANDBOX/.notebook/specs/SPEC-001/SUMMARY.md"
  run run_in_sandbox ".notebook/specs/SPEC-001/plan-2"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.notebook/specs/SPEC-001/plan-2"
}

# --- 3c. Real summary-verify.sh delegation: well-formed SUMMARY.md -> deleted

@test "colocated plan: real summary-verify.sh present + well-formed parent SUMMARY.md -> plan/ deleted" {
  copy_summary_verify
  seed_plan ".notebook/specs/SPEC-021/plan"
  echo "spec body" > "$SANDBOX/.notebook/specs/SPEC-021/SPEC.md"
  cat > "$SANDBOX/.notebook/specs/SPEC-021/SUMMARY.md" <<'EOF'
---
wiki_promote_default: ask
wiki_promote_targets: [decisions]
---
# SPEC-021

Consolidated body.
EOF
  seed_close spec:SPEC-021 gaia-plan
  run run_in_sandbox ".notebook/specs/SPEC-021/plan"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.notebook/specs/SPEC-021/plan"
  grep -qF "Deleted plan folder: .notebook/specs/SPEC-021/plan" <<<"$output"
}

# --- 3d. Real summary-verify.sh delegation: malformed SUMMARY.md -> kept ----

@test "colocated plan: real summary-verify.sh present + malformed parent SUMMARY.md -> plan/ kept" {
  copy_summary_verify
  seed_plan ".notebook/specs/SPEC-022/plan"
  echo "spec body" > "$SANDBOX/.notebook/specs/SPEC-022/SPEC.md"
  echo "not well-formed" > "$SANDBOX/.notebook/specs/SPEC-022/SUMMARY.md"
  seed_close spec:SPEC-022 gaia-plan
  run run_in_sandbox ".notebook/specs/SPEC-022/plan"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.notebook/specs/SPEC-022/plan" ]
  grep -qF "Retained plan" <<<"$output"
}

# --- 4. A slug-named plan folder is not a plan folder of the notebook --------

@test "slug-named plan folder in the notebook is refused, usage.sh represented never called" {
  mkdir -p "$SANDBOX/.notebook/plans/bare/.work"
  echo "kickoff" > "$SANDBOX/.notebook/plans/bare/KICKOFF.md"
  : > "$SANDBOX/.notebook/plans/bare/RUNNING"
  echo "scratch" > "$SANDBOX/.notebook/plans/bare/.work/x"
  stub_usage_script
  run run_in_sandbox ".notebook/plans/bare"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.notebook/plans/bare" ]
  [ -f "$SANDBOX/.notebook/plans/bare/KICKOFF.md" ]
  [ -f "$SANDBOX/.notebook/plans/bare/RUNNING" ]
  [ ! -e "$SANDBOX/usage-calls.log" ]
  grep -qF "plan-archive: refusing .notebook/plans/bare" <<<"$output"
}

# --- 5. Gate blocks: no close row -> kept with the recovery command ----------

@test "gate blocks: no close row for the plan -> folder kept, keep line names the ref and the recovery command" {
  seed_plan ".notebook/plans/PLAN-006"
  seed_plan_row PLAN-006
  run run_in_sandbox ".notebook/plans/PLAN-006"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.notebook/plans/PLAN-006" ]
  [ -f "$SANDBOX/.notebook/plans/PLAN-006/PROGRESS.md" ]
  [ "$output" = "Kept .notebook/plans/PLAN-006: no gaia-plan run recorded for plan:PLAN-006; outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record plan:PLAN-006 --workflow gaia-plan --start <iso>" ]
}

@test "gate blocks: a gaia-spec close for the plan ref does not clear it" {
  seed_plan ".notebook/plans/PLAN-006"
  seed_close plan:PLAN-006 gaia-spec
  run run_in_sandbox ".notebook/plans/PLAN-006"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.notebook/plans/PLAN-006/PROGRESS.md" ]
  grep -qF "no gaia-plan run recorded for plan:PLAN-006" <<<"$output"
}

@test "gate blocks: usage.jsonl missing -> folder kept, keep line names the ledger path" {
  seed_plan ".notebook/plans/PLAN-006"
  rm -f "$TELEMETRY/usage.jsonl"
  run run_in_sandbox ".notebook/plans/PLAN-006"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.notebook/plans/PLAN-006/PROGRESS.md" ]
  [ "$output" = "Kept .notebook/plans/PLAN-006: usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for plan:PLAN-006; once it reads, outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record plan:PLAN-006 --workflow gaia-plan --start <iso>" ]
}

@test "gate blocks: colocated plan with usage.jsonl missing -> kept, keep line names the spec ref" {
  seed_plan ".notebook/specs/SPEC-007/plan"
  echo "# SPEC-007" > "$SANDBOX/.notebook/specs/SPEC-007/SUMMARY.md"
  rm -f "$TELEMETRY/usage.jsonl"
  run run_in_sandbox ".notebook/specs/SPEC-007/plan"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.notebook/specs/SPEC-007/plan" ]
  grep -qF "usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for spec:SPEC-007" <<<"$output"
}

# --- 6. Row stamp still applies even when the gate blocks the reduce ---------

@test "PLAN-NNN folder: row stamp still applies even when the usage-ledger gate blocks the reduce" {
  seed_plan ".notebook/plans/PLAN-007"
  seed_plan_row PLAN-007
  run run_in_sandbox ".notebook/plans/PLAN-007"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.notebook/plans/PLAN-007" ]
  [ "$(plan_row_field PLAN-007 status)" = "merged" ]
  [ -n "$(plan_row_field PLAN-007 merged_at)" ]
  grep -qF "Kept .notebook/plans/PLAN-007" <<<"$output"
}

# --- 7. Slug-named folder: no row stamp attempt -----------------------------

@test "slug-named folder: refused, and no unrelated row is stamped" {
  seed_plan ".notebook/plans/cache-consolidation"
  seed_plan_row PLAN-005
  run run_in_sandbox ".notebook/plans/cache-consolidation"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.notebook/plans/cache-consolidation" ]
  # Unrelated PLAN-005 row is untouched, proving no stray stamp fired.
  [ "$(plan_row_field PLAN-005 status)" = "ready" ]
}

# --- 8. Spec-colocated plan: deletion never stamps any plan row --------------

@test "spec-colocated plan: deletion never stamps any plan row" {
  seed_plan ".notebook/specs/SPEC-006/plan"
  echo "# SPEC-006" > "$SANDBOX/.notebook/specs/SPEC-006/SUMMARY.md"
  seed_close spec:SPEC-006 gaia-plan
  seed_plan_row PLAN-005
  catalog_before="$(snapshot_file "$CATALOG")"
  run run_in_sandbox ".notebook/specs/SPEC-006/plan"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.notebook/specs/SPEC-006/plan"
  assert_files_identical "$CATALOG" "$catalog_before"
}

# --- 9. Best-effort: a missing catalog row for the stamp never blocks reduce -

@test "PLAN-NNN with no matching catalog row: stamp is a no-op but reduce still proceeds" {
  seed_plan ".notebook/plans/PLAN-999"
  seed_close plan:PLAN-999 gaia-plan
  seed_plan_row PLAN-001
  run run_in_sandbox ".notebook/plans/PLAN-999"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.notebook/plans/PLAN-999" ]
  [ -f "$SANDBOX/.notebook/plans/PLAN-999/SUMMARY.md" ]
  [ ! -e "$SANDBOX/.notebook/plans/PLAN-999/RUNNING" ]
}

# --- 9b. Spec-less PLAN-NNN with no SUMMARY.md yet: kept, not reduced ------

@test "spec-less PLAN-NNN with no SUMMARY.md yet: kept intact, not reduced (fail-closed consolidation gate)" {
  local plan_directory="$SANDBOX/.notebook/plans/PLAN-010"
  mkdir -p "$plan_directory/.work"
  echo "progress" > "$plan_directory/PROGRESS.md"
  : > "$plan_directory/RUNNING"
  seed_close plan:PLAN-010 gaia-plan
  seed_plan_row PLAN-010
  run run_in_sandbox ".notebook/plans/PLAN-010"
  [ "$status" -eq 0 ]
  [ -f "$plan_directory/PROGRESS.md" ]
  [ -f "$plan_directory/RUNNING" ]
  grep -qF "Retained plan (no consolidated SUMMARY.md yet)" <<<"$output"
}

# --- 9c. The gate reads the main checkout's ledger, not the cwd tree's -------

@test "linked worktree: the ledger under the main checkout, reached through --main-root, clears the gate" {
  rm -rf "$SANDBOX"
  fixture="$(_fixture_repository --worktree-bare w)"
  main_checkout="$(printf '%s\n' "$fixture" | sed -n 1p)"
  LINKED="$(printf '%s\n' "$fixture" | sed -n 2p)"
  SANDBOX="$main_checkout"
  CATALOG="$main_checkout/.notebook/catalog.json"
  TELEMETRY="$main_checkout/.gaia/local/telemetry"
  seed_plan ".notebook/plans/PLAN-040"
  seed_plan_row PLAN-040
  # The only usage ledger lives under the main checkout, outside the cwd tree.
  seed_close plan:PLAN-040 gaia-plan
  [ ! -e "$LINKED/.gaia/local/telemetry/usage.jsonl" ]

  run bash -c 'cd "$1" && "$2" .notebook/plans/PLAN-040' _ "$LINKED" "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "Reduced plan folder to SUMMARY.md (kept for age-reap): .notebook/plans/PLAN-040" <<<"$output"
  [ ! -e "$main_checkout/.notebook/plans/PLAN-040/PROGRESS.md" ]
  [ "$(plan_row_field PLAN-040 status)" = "merged" ]

  # A plan the main checkout's ledger does not record is kept: the answer
  # comes from that ledger, not from a default.
  seed_plan ".notebook/plans/PLAN-041"
  run bash -c 'cd "$1" && "$2" .notebook/plans/PLAN-041' _ "$LINKED" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$main_checkout/.notebook/plans/PLAN-041/PROGRESS.md" ]
  grep -qF "no gaia-plan run recorded for plan:PLAN-041" <<<"$output"
}

@test "linked worktree with a notebook link: an absolute path through the link acts on main's folder" {
  rm -rf "$SANDBOX"
  fixture="$(_fixture_repository --worktree w)"
  main_checkout="$(printf '%s\n' "$fixture" | sed -n 1p)"
  LINKED="$(printf '%s\n' "$fixture" | sed -n 2p)"
  SANDBOX="$main_checkout"
  CATALOG="$main_checkout/.notebook/catalog.json"
  TELEMETRY="$main_checkout/.gaia/local/telemetry"
  seed_plan ".notebook/plans/PLAN-042"
  seed_plan_row PLAN-042
  seed_close plan:PLAN-042 gaia-plan

  run bash -c 'cd "$1" && "$2" "$1/.notebook/plans/PLAN-042"' _ "$LINKED" "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "Reduced plan folder to SUMMARY.md (kept for age-reap): .notebook/plans/PLAN-042" <<<"$output"
  [ ! -e "$main_checkout/.notebook/plans/PLAN-042/PROGRESS.md" ]
  [ -f "$main_checkout/.notebook/plans/PLAN-042/SUMMARY.md" ]
}

# --- 10. Refuse operating inside the archived/ tree -------------------------

@test "refuses the notebook plans archived/<slug> (nested-under-archived guard)" {
  seed_plan ".notebook/plans/archived/foo"
  run run_in_sandbox ".notebook/plans/archived/foo"
  [ "$status" -eq 0 ]
  # Untouched: every seeded entry still present, nothing pruned or deleted.
  [ -f "$SANDBOX/.notebook/plans/archived/foo/KICKOFF.md" ]
  [ -f "$SANDBOX/.notebook/plans/archived/foo/RUNNING" ]
  [ -f "$SANDBOX/.notebook/plans/archived/foo/.work/x" ]
  grep -qF "refusing" <<<"$output"
}

# --- 11. Refuse out-of-shape relative path ----------------------------------

@test "refuses a relative path outside the notebook" {
  mkdir -p "$SANDBOX/some/other/dir"
  : > "$SANDBOX/some/other/dir/file"
  run run_in_sandbox "some/other/dir"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/some/other/dir/file" ]
  grep -qF "refusing" <<<"$output"
}

@test "refuses the pre-notebook local locations and leaves them untouched" {
  seed_plan ".gaia/local/plans/PLAN-001"
  seed_plan ".gaia/local/specs/SPEC-001/plan"
  seed_close plan:PLAN-001 gaia-plan
  before="$(listing)"
  run run_in_sandbox ".gaia/local/plans/PLAN-001"
  [ "$status" -eq 0 ]
  grep -qF "refusing" <<<"$output"
  run run_in_sandbox ".gaia/local/specs/SPEC-001/plan"
  [ "$status" -eq 0 ]
  grep -qF "refusing" <<<"$output"
  [ "$(listing)" = "$before" ]
}

@test "a refusal prints the accepted locations from the library, not a spelled path" {
  run run_in_sandbox "some/other/dir"
  [ "$status" -eq 0 ]
  expected_plans="$(cd "$SANDBOX" && GAIA_NOTEBOOK_TREE="$SANDBOX" bash .gaia/scripts/notebook/notebook-lib.sh path plan)"
  expected_specs="$(cd "$SANDBOX" && GAIA_NOTEBOOK_TREE="$SANDBOX" bash .gaia/scripts/notebook/notebook-lib.sh path spec)"
  grep -qF "$expected_plans" <<<"$output"
  grep -qF "$expected_specs" <<<"$output"
}

# --- 12. Non-existent input --------------------------------------------------

@test "non-existent plan_dir: exit 0, stderr note, no side effects" {
  run run_in_sandbox ".notebook/plans/PLAN-077"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/.notebook/plans/PLAN-077" ]
  grep -qF "does not exist" <<<"$output"
}

# --- 13. Absolute-under-repo normalizes -------------------------------------

@test "absolute path under repo root normalizes to the same end-state" {
  seed_plan ".notebook/plans/PLAN-030"
  seed_close plan:PLAN-030 gaia-plan
  run run_in_sandbox "$SANDBOX/.notebook/plans/PLAN-030"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/.notebook/plans/PLAN-030/PROGRESS.md" ]
  grep -qF "Reduced plan folder to SUMMARY.md (kept for age-reap): .notebook/plans/PLAN-030" <<<"$output"
}

@test "an absolute and a repo-relative spelling reach the same end-state" {
  seed_plan ".notebook/plans/PLAN-001"
  seed_plan ".notebook/plans/PLAN-002"
  seed_close plan:PLAN-001 gaia-plan
  seed_close plan:PLAN-002 gaia-plan
  run run_in_sandbox "$SANDBOX/.notebook/plans/PLAN-001"
  [ "$status" -eq 0 ]
  run run_in_sandbox ".notebook/plans/PLAN-002"
  [ "$status" -eq 0 ]
  for plan_name in PLAN-001 PLAN-002; do
    [ -f "$SANDBOX/.notebook/plans/$plan_name/SUMMARY.md" ]
    [ ! -e "$SANDBOX/.notebook/plans/$plan_name/RUNNING" ]
    [ "$(find "$SANDBOX/.notebook/plans/$plan_name" -mindepth 1 | wc -l | tr -d ' ')" = "1" ]
  done
}

# --- 14. Absolute-outside-repo refuses ----------------------------------------

@test "absolute path outside repo root refuses" {
  OUTSIDE_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/outside.XXXXXX")"
  OUTSIDE="$(cd "$OUTSIDE_RAW" && pwd -P)"
  mkdir -p "$OUTSIDE/plans/PLAN-001"
  : > "$OUTSIDE/plans/PLAN-001/SUMMARY.md"
  run run_in_sandbox "$OUTSIDE/plans/PLAN-001"
  [ "$status" -eq 0 ]
  [ -f "$OUTSIDE/plans/PLAN-001/SUMMARY.md" ]
  grep -qF "refusing" <<<"$output"
}

# --- 15. Refuse "." slug (would resolve to plans/ itself, mass-deleting siblings) --

@test "refuses the notebook plans folder plus a dot segment (mass-delete guard)" {
  seed_plan ".notebook/plans/PLAN-011"
  mkdir -p "$SANDBOX/.notebook/plans/PLAN-012"
  : > "$SANDBOX/.notebook/plans/PLAN-012/marker"
  run run_in_sandbox ".notebook/plans/."
  [ "$status" -eq 0 ]
  # Untouched: sibling plan folders inside plans/ survive.
  [ -f "$SANDBOX/.notebook/plans/PLAN-011/KICKOFF.md" ]
  [ -f "$SANDBOX/.notebook/plans/PLAN-011/.work/x" ]
  [ -f "$SANDBOX/.notebook/plans/PLAN-012/marker" ]
  grep -qF "refusing" <<<"$output"
}

# --- 16. Refuse ".." slug ------------------------------------------------------

@test "refuses the notebook plans folder plus a parent segment (mass-delete guard)" {
  seed_plan ".notebook/plans/PLAN-011"
  seed_plan ".notebook/specs/SPEC-005/plan"
  run run_in_sandbox ".notebook/plans/.."
  [ "$status" -eq 0 ]
  # Untouched: sibling trees under the notebook survive.
  [ -f "$SANDBOX/.notebook/plans/PLAN-011/KICKOFF.md" ]
  [ -f "$SANDBOX/.notebook/specs/SPEC-005/plan/KICKOFF.md" ]
  grep -qF "refusing" <<<"$output"
}

# --- 17. Refuse doubled trailing slash (empty slug, same mass-delete guard) --------

@test "refuses the notebook plans folder with a doubled trailing slash (empty slug)" {
  seed_plan ".notebook/plans/PLAN-011"
  mkdir -p "$SANDBOX/.notebook/plans/PLAN-012"
  : > "$SANDBOX/.notebook/plans/PLAN-012/marker"
  run run_in_sandbox ".notebook/plans//"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.notebook/plans/PLAN-011/KICKOFF.md" ]
  [ -f "$SANDBOX/.notebook/plans/PLAN-012/marker" ]
  grep -qF "refusing" <<<"$output"
}

# --- 18. Well-formed slug with a single trailing slash still resolves ------------

@test "trailing slash on a well-formed slug still resolves correctly" {
  seed_plan ".notebook/plans/PLAN-031"
  seed_close plan:PLAN-031 gaia-plan
  run run_in_sandbox ".notebook/plans/PLAN-031/"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/.notebook/plans/PLAN-031/PROGRESS.md" ]
  grep -qF "Reduced plan folder to SUMMARY.md (kept for age-reap): .notebook/plans/PLAN-031" <<<"$output"
}

# --- 19. Refuse a specs-arm path that climbs out ------------------------------------

@test "refuses the notebook specs folder plus a parent segment (spec-part path escape)" {
  seed_plan ".notebook/specs/SPEC-005/plan"
  mkdir -p "$SANDBOX/.notebook/plan"
  : > "$SANDBOX/.notebook/plan/escaped-marker"
  run run_in_sandbox ".notebook/specs/../plan"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.notebook/specs/SPEC-005/plan/KICKOFF.md" ]
  [ -f "$SANDBOX/.notebook/plan/escaped-marker" ]
  grep -qF "refusing" <<<"$output"
}

# --- 20. Classification red twins ------------------------------------------------

@test "refuses a climb out of the plans folder into the specs folder, untouched" {
  seed_plan ".notebook/specs/SPEC-001"
  echo "# SPEC-001" > "$SANDBOX/.notebook/specs/SPEC-001/SUMMARY.md"
  seed_close spec:SPEC-001 gaia-plan
  before="$(listing)"
  run run_in_sandbox ".notebook/plans/../specs/SPEC-001"
  [ "$status" -eq 0 ]
  grep -qF "refusing" <<<"$output"
  [ "$(listing)" = "$before" ]
}

@test "refuses a path that names a child of a plan folder or a dot segment after it, untouched" {
  seed_plan ".notebook/plans/PLAN-001"
  seed_plan ".notebook/plans/PLAN-002"
  seed_close plan:PLAN-001 gaia-plan
  seed_close plan:PLAN-002 gaia-plan
  before="$(listing)"
  for candidate in ".notebook/plans/PLAN-001/.work" ".notebook/plans/PLAN-001/.." ".notebook/plans/PLAN-001/../PLAN-002"; do
    run run_in_sandbox "$candidate"
    [ "$status" -eq 0 ]
    grep -qF "refusing" <<<"$output"
  done
  [ "$(listing)" = "$before" ]
}

@test "refuses a symlinked plan folder and leaves the folder it points at untouched" {
  outside="$BATS_TEST_TMPDIR/outside-target"
  mkdir -p "$outside/.work"
  echo "precious" > "$outside/SUMMARY.md"
  echo "progress" > "$outside/PROGRESS.md"
  mkdir -p "$SANDBOX/.notebook/plans"
  ln -s "$outside" "$SANDBOX/.notebook/plans/PLAN-002"
  seed_close plan:PLAN-002 gaia-plan
  run run_in_sandbox ".notebook/plans/PLAN-002"
  [ "$status" -eq 0 ]
  grep -qF "refusing" <<<"$output"
  [ -L "$SANDBOX/.notebook/plans/PLAN-002" ]
  [ "$(cat "$outside/SUMMARY.md")" = "precious" ]
  [ -f "$outside/PROGRESS.md" ]
}

@test "refuses a symlinked colocated plan folder and leaves the folder it points at untouched" {
  outside="$BATS_TEST_TMPDIR/outside-plan"
  mkdir -p "$outside"
  echo "precious" > "$outside/PROGRESS.md"
  mkdir -p "$SANDBOX/.notebook/specs/SPEC-001"
  echo "# SPEC-001" > "$SANDBOX/.notebook/specs/SPEC-001/SUMMARY.md"
  ln -s "$outside" "$SANDBOX/.notebook/specs/SPEC-001/plan"
  seed_close spec:SPEC-001 gaia-plan
  run run_in_sandbox ".notebook/specs/SPEC-001/plan"
  [ "$status" -eq 0 ]
  grep -qF "refusing" <<<"$output"
  [ -L "$SANDBOX/.notebook/specs/SPEC-001/plan" ]
  [ "$(cat "$outside/PROGRESS.md")" = "precious" ]
}

@test "refuses an absolute path outside the notebook that merely has plans in its name" {
  mkdir -p "$BATS_TEST_TMPDIR/x/plans/PLAN-001"
  echo "summary" > "$BATS_TEST_TMPDIR/x/plans/PLAN-001/SUMMARY.md"
  echo "progress" > "$BATS_TEST_TMPDIR/x/plans/PLAN-001/PROGRESS.md"
  run run_in_sandbox "$BATS_TEST_TMPDIR/x/plans/PLAN-001"
  [ "$status" -eq 0 ]
  grep -qF "refusing" <<<"$output"
  [ -f "$BATS_TEST_TMPDIR/x/plans/PLAN-001/PROGRESS.md" ]
}

# --- 21. Readiness -----------------------------------------------------------------

@test "not ready (move pending): exit 0, the move line on stderr, the folder untouched" {
  rm -rf "$SANDBOX"
  SANDBOX="$(_fixture_repository --legacy)"
  CATALOG="$SANDBOX/.notebook/catalog.json"
  TELEMETRY="$SANDBOX/.gaia/local/telemetry"
  seed_plan ".notebook/plans/PLAN-001"
  seed_close plan:PLAN-001 gaia-plan
  seed_plan_row PLAN-001
  before="$(listing)"
  run --separate-stderr run_in_sandbox ".notebook/plans/PLAN-001"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$stderr"
  [ "$(listing)" = "$before" ]
  [ "$(plan_row_field PLAN-001 status)" = "ready" ]
}
