#!/usr/bin/env bats
# Tests for `.gaia/scripts/spec/plan-reconcile.sh`, the plan-arm
# counterpart to `spec-reconcile.sh` (see spec-reconcile.bats for the spec
# arm). The single-id form is orchestrator-driven: the caller already knows
# the merge is confirmed and the plan_id, so it never touches the network, and
# an optional third argument stamps the confirmed PR number. The no-id scan
# form is the backstop that matches rows to merged PRs through one gh call.
# Plan age anchors on `merged_at`, so this arm writes status "merged", not the
# retired "completed".
#
# Per-test fixture via helpers/tmp-notebook-repo.sh: a git repo carrying the
# notebook library, the spec scripts and a catalog seeded with one ready plan
# row. The fixture's repository also gives ledger-update.sh a real checkout to
# resolve main against.

bats_require_minimum_version 1.5.0

# Builds the throwaway fixture repository the suite acts on.
_fixture_repository() {
  "$THIS_DIRECTORY/helpers/tmp-notebook-repo.sh" "$@"
}

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  SOURCE_LIBRARY_DIRECTORY="$REPO_ROOT/.gaia/scripts/spec"
  [ -x "$SOURCE_LIBRARY_DIRECTORY/plan-reconcile.sh" ]

  SANDBOX="$(_fixture_repository \
    --seed-row '{"kind":"plan","id":"PLAN-005","path":"plans/PLAN-005","status":"ready","subject":"x","source":"allocated","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z"}')"
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    rm -rf "$SANDBOX"
  fi
}

CATALOG_RELATIVE_PATH=".notebook/catalog.json"

_reconcile() {
  bash "$SANDBOX/.gaia/scripts/spec/plan-reconcile.sh" "$SANDBOX" "$@"
}

_reconcile_scan() {
  bash "$SANDBOX/.gaia/scripts/spec/plan-reconcile.sh" "$SANDBOX"
}

_row_field() {
  local id="$1" field="$2"
  jq -r --arg id "$id" --arg field_name "$field" \
    '.items[] | select(.kind == "plan" and .id == $id) | .[$field_name] // "null"' \
    "$SANDBOX/$CATALOG_RELATIVE_PATH"
}

_row_json() {
  jq -c --arg id "$1" '.items[] | select(.kind == "plan" and .id == $id)' "$SANDBOX/$CATALOG_RELATIVE_PATH"
}

@test "1: ready PLAN-005 flips to merged with an ISO merged_at, exit 0" {
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  grep -qF "reconciled PLAN-005 -> merged" <<<"$output"
  [ "$(_row_field PLAN-005 status)" = "merged" ]
  case "$(_row_field PLAN-005 merged_at)" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
}

@test "1b: the flip does not depend on any plan folder existing" {
  # No PLAN-005 folder anywhere under the sandbox; the flip must still land.
  [ ! -d "$SANDBOX/.notebook/plans/PLAN-005" ]
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  [ "$(_row_field PLAN-005 status)" = "merged" ]
}

@test "2: idempotent; a second run re-stamps merged and exits 0" {
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  [ "$(_row_field PLAN-005 status)" = "merged" ]
}

@test "3: a non-PLAN-NNN id is a no-op, exits 0, leaves the catalog unchanged" {
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  for id in cache-thing PLAN-x; do
    run _reconcile "$id"
    [ "$status" -eq 0 ]
  done
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after"
}

@test "4a: a missing catalog exits 0 and creates nothing" {
  rm -f "$SANDBOX/$CATALOG_RELATIVE_PATH"
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  [ ! -f "$SANDBOX/$CATALOG_RELATIVE_PATH" ]
}

@test "4b: a missing row exits 0 and leaves the catalog unchanged" {
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  run _reconcile PLAN-999
  [ "$status" -eq 0 ]
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after"
}

@test "5: the plans status vocabulary guard holds; plan-reconcile never writes the retired 'completed' status" {
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  grep -qF -- "-> completed" <<<"$output" && return 1
  [ "$(_row_field PLAN-005 status)" = "merged" ]
}

# --- optional third argument: the confirmed PR number -------------------------

# _gh_stub_that_fails: a gh on PATH that records its invocation and fails, so a
# test proves the single-id form never reaches the network.
_gh_stub_that_fails() {
  STUB_DIRECTORY="$BATS_TEST_TMPDIR/stub-fail"
  mkdir -p "$STUB_DIRECTORY"
  printf '#!/usr/bin/env bash\necho invoked >> "%s/gh-called"\nexit 1\n' "$STUB_DIRECTORY" > "$STUB_DIRECTORY/gh"
  chmod +x "$STUB_DIRECTORY/gh"
  PATH="$STUB_DIRECTORY:$PATH"
}

@test "6: a positive-integer third argument stamps pr_number as a JSON number, with no network call" {
  _gh_stub_that_fails
  run _reconcile PLAN-005 2601
  [ "$status" -eq 0 ]
  grep -qF "reconciled PLAN-005 -> merged" <<<"$output"
  [ "$(_row_field PLAN-005 status)" = "merged" ]
  jq -e '.items[] | select(.kind == "plan" and .id == "PLAN-005") | .pr_number == 2601' "$SANDBOX/$CATALOG_RELATIVE_PATH"
  [ ! -e "$STUB_DIRECTORY/gh-called" ]
}

@test "6b: the two-argument form matches the pre-change script: same stdout, stderr and exit, no pr_number, no network" {
  _gh_stub_that_fails
  # The committed script still names the retired two-script chokepoint; point
  # that call at the merged one, and its one wording the catalog changed
  # (the missing-row stderr line) at the new text, so only the third-argument
  # behavior differs.
  git -C "$REPO_ROOT" show HEAD:.gaia/scripts/spec/plan-reconcile.sh \
    | sed -e 's#/plan-\(ledger-update\.sh\)#/\1#g' -e 's#missing ledger/row#missing catalog row#' >"$SANDBOX/.gaia/scripts/spec/plan-reconcile-before.sh"
  for id in PLAN-005 PLAN-x cache-thing PLAN-999; do
    run --separate-stderr bash "$SANDBOX/.gaia/scripts/spec/plan-reconcile-before.sh" "$SANDBOX" "$id"
    before_status="$status" before_output="$output" before_stderr="$stderr"
    run --separate-stderr _reconcile "$id"
    [ "$status" -eq "$before_status" ]
    [ "$output" = "$before_output" ]
    [ "$stderr" = "$before_stderr" ]
  done
  [ "$(_row_field PLAN-005 pr_number)" = "null" ]
  [ ! -e "$STUB_DIRECTORY/gh-called" ]
}

@test "6c: a non-numeric third argument stamps without pr_number, names the value on stderr and exits 0" {
  for bad in abc 0 007 -4 12x ""; do
    run --separate-stderr _reconcile PLAN-005 "$bad"
    [ "$status" -eq 0 ]
    [ "$stderr" = "plan-reconcile: $bad is not a PR number; stamped without pr_number" ]
    grep -qF "reconciled PLAN-005 -> merged" <<<"$output"
    [ "$(_row_field PLAN-005 status)" = "merged" ]
    [ "$(_row_field PLAN-005 pr_number)" = "null" ]
  done
}

# --- scan mode: reconcile against merged pull requests ------------------------

_seed_scan_catalog() {
  jq '.items = [
    {"kind":"plan","id":"PLAN-031","path":"plans/PLAN-031","status":"ready","subject":"a","source":"allocated","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z"},
    {"kind":"plan","id":"PLAN-032","path":"plans/PLAN-032","status":"merged","subject":"b","source":"allocated","created_at":"2026-01-02T00:00:00Z","status_changed_at":"2026-02-01T00:00:00Z","merged_at":"2026-02-01T00:00:00Z"},
    {"kind":"plan","id":"PLAN-033","path":"plans/PLAN-033","status":"ready","subject":"c","source":"allocated","created_at":"2026-01-03T00:00:00Z","status_changed_at":"2026-01-03T00:00:00Z"},
    {"kind":"plan","id":"PLAN-034","path":"plans/PLAN-034","status":"merged","subject":"d","source":"allocated","created_at":"2026-01-04T00:00:00Z","status_changed_at":"2026-02-02T00:00:00Z","merged_at":"2026-02-02T00:00:00Z","pr_number":70}
  ]' "$SANDBOX/$CATALOG_RELATIVE_PATH" > "$BATS_TEST_TMPDIR/seeded-catalog.json"
  cp "$BATS_TEST_TMPDIR/seeded-catalog.json" "$SANDBOX/$CATALOG_RELATIVE_PATH"
}

_gh_stub_listing() {
  STUB_DIRECTORY="$BATS_TEST_TMPDIR/stub-list"
  mkdir -p "$STUB_DIRECTORY"
  cat > "$STUB_DIRECTORY/gh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"number": 100, "headRefName": "feat/plan-031-first", "mergedAt": "2026-03-01T00:00:00Z"},
  {"number": 101, "headRefName": "feat/plan-031-second", "mergedAt": "2026-03-05T00:00:00Z"},
  {"number": 102, "headRefName": "fix/plan-032-x", "mergedAt": "2026-03-02T00:00:00Z"},
  {"number": 103, "headRefName": "feat/plan-034-x", "mergedAt": "2026-03-03T00:00:00Z"},
  {"number": 104, "headRefName": "feat/spec-033-x", "mergedAt": "2026-03-04T00:00:00Z"},
  {"number": 105, "headRefName": "feat/plan-099-x", "mergedAt": "2026-03-06T00:00:00Z"}
]
JSON
EOF
  chmod +x "$STUB_DIRECTORY/gh"
  PATH="$STUB_DIRECTORY:$PATH"
}

@test "7: scan mode matches ready and pr_number-less merged rows to the newest merged PR naming the plan" {
  _seed_scan_catalog
  _gh_stub_listing
  run _reconcile_scan
  [ "$status" -eq 0 ]
  [ "$(_row_field PLAN-031 status)" = "merged" ]
  [ "$(_row_field PLAN-031 merged_at)" = "2026-03-05T00:00:00Z" ]
  jq -e '.items[] | select(.kind == "plan" and .id == "PLAN-031") | .pr_number == 101' "$SANDBOX/$CATALOG_RELATIVE_PATH"
  [ "$(_row_field PLAN-032 status)" = "merged" ]
  [ "$(_row_field PLAN-032 merged_at)" = "2026-03-02T00:00:00Z" ]
  jq -e '.items[] | select(.kind == "plan" and .id == "PLAN-032") | .pr_number == 102' "$SANDBOX/$CATALOG_RELATIVE_PATH"
}

@test "7b: scan mode leaves unmatched rows and rows that already carry pr_number byte-identical" {
  _seed_scan_catalog
  _gh_stub_listing
  expected_unmatched="$(_row_json PLAN-033)"
  expected_confirmed="$(_row_json PLAN-034)"
  run _reconcile_scan
  [ "$status" -eq 0 ]
  [ "$(_row_json PLAN-033)" = "$expected_unmatched" ]
  [ "$(_row_json PLAN-034)" = "$expected_confirmed" ]
}

@test "7c: scan mode with no gh on PATH leaves the catalog byte-identical and exits 0" {
  _seed_scan_catalog
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  # A PATH holding only the tools the script needs, and no gh.
  bare="$BATS_TEST_TMPDIR/bare-bin"
  mkdir -p "$bare"
  for tool in bash jq git sed sort tail date cat dirname basename mkdir rm mv grep awk tr head cut wc uname env mktemp; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [ -z "$tool_path" ] || ln -sf "$tool_path" "$bare/$tool"
  done
  PATH="$bare" run bash "$SANDBOX/.gaia/scripts/spec/plan-reconcile.sh" "$SANDBOX"
  [ "$status" -eq 0 ]
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after"
}

@test "7d: scan mode with a failing gh leaves the catalog byte-identical and exits 0" {
  _seed_scan_catalog
  _gh_stub_that_fails
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  run _reconcile_scan
  [ "$status" -eq 0 ]
  [ -e "$STUB_DIRECTORY/gh-called" ]
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after"
}

@test "7e: a zero-argument call prints the usage line naming both forms and exits 0" {
  run --separate-stderr bash "$SANDBOX/.gaia/scripts/spec/plan-reconcile.sh"
  [ "$status" -eq 0 ]
  grep -qF "usage: plan-reconcile.sh <repo_root> [<plan_id> [<pr_number>]]" <<<"$stderr"
}

@test "7f: scan mode ignores a same-number PR merged before the row was created and leaves the row ready" {
  jq '.items = [{"kind":"plan","id":"PLAN-031","path":"plans/PLAN-031","status":"ready","subject":"a","source":"allocated","created_at":"2026-03-10T00:00:00Z","status_changed_at":"2026-03-10T00:00:00Z"}]' \
    "$SANDBOX/$CATALOG_RELATIVE_PATH" > "$BATS_TEST_TMPDIR/seeded-catalog.json"
  cp "$BATS_TEST_TMPDIR/seeded-catalog.json" "$SANDBOX/$CATALOG_RELATIVE_PATH"
  _gh_stub_listing
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  run _reconcile_scan
  [ "$status" -eq 0 ]
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after"
  [ "$(_row_field PLAN-031 status)" = "ready" ]
}

@test "7g: scan mode still matches a same-number PR merged after the row was created when an older one shares the number" {
  jq '.items = [{"kind":"plan","id":"PLAN-031","path":"plans/PLAN-031","status":"ready","subject":"a","source":"allocated","created_at":"2026-03-03T00:00:00Z","status_changed_at":"2026-03-03T00:00:00Z"}]' \
    "$SANDBOX/$CATALOG_RELATIVE_PATH" > "$BATS_TEST_TMPDIR/seeded-catalog.json"
  cp "$BATS_TEST_TMPDIR/seeded-catalog.json" "$SANDBOX/$CATALOG_RELATIVE_PATH"
  _gh_stub_listing
  run _reconcile_scan
  [ "$status" -eq 0 ]
  [ "$(_row_field PLAN-031 status)" = "merged" ]
  jq -e '.items[] | select(.kind == "plan" and .id == "PLAN-031") | .pr_number == 101' "$SANDBOX/$CATALOG_RELATIVE_PATH"
}

# --- readiness: the one-time move pending --------------------------------------

@test "8: not ready, the single-id form prints the move line on stderr, exits 0 and changes nothing" {
  rm -rf "$SANDBOX"
  SANDBOX="$(_fixture_repository --legacy \
    --seed-row '{"kind":"plan","id":"PLAN-005","path":"plans/PLAN-005","status":"ready","subject":"x","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z"}')"
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  run --separate-stderr _reconcile PLAN-005 2601
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$stderr"
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after"
  [ "$(_row_field PLAN-005 status)" = "ready" ]
}

@test "8b: not ready, the scan form prints the move line on stderr, never reaches gh and changes nothing" {
  rm -rf "$SANDBOX"
  SANDBOX="$(_fixture_repository --legacy \
    --seed-row '{"kind":"plan","id":"PLAN-031","path":"plans/PLAN-031","status":"ready","subject":"a","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z"}')"
  _gh_stub_listing
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  run --separate-stderr _reconcile_scan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$stderr"
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after"
  [ "$(_row_field PLAN-031 status)" = "ready" ]
}

@test "9: run from the real repo root, the scan acts on the operand's fixture only" {
  _seed_scan_catalog
  _gh_stub_listing
  real_before="$(directory_listing_checksum "$REPO_ROOT/.notebook")"
  run bash -c 'cd "$1" && bash "$2/.gaia/scripts/spec/plan-reconcile.sh" "$2"' _ "$REPO_ROOT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(_row_field PLAN-031 status)" = "merged" ]
  real_after="$(directory_listing_checksum "$REPO_ROOT/.notebook")"
  [ "$real_after" = "$real_before" ]
}
