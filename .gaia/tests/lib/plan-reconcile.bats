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
# Fixture via helpers/tmp-notebook-repo.sh: a git repo carrying the notebook
# library, the spec scripts and a catalog seeded with one ready plan row. It is
# built once in setup_file and copied for every case, so each case starts from
# the seeded catalog. The fixture's repository also gives ledger-update.sh a
# real checkout to resolve main against.

bats_require_minimum_version 1.5.0

THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
CATALOG_RELATIVE_PATH=".notebook/catalog.json"
SEED_ROW='{"kind":"plan","id":"PLAN-005","path":"plans/PLAN-005","status":"ready","subject":"x","source":"allocated","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z"}'

# Builds the throwaway fixture repository the suite acts on.
_fixture_repository() {
  "$THIS_DIRECTORY/helpers/tmp-notebook-repo.sh" "$@"
}

setup_file() {
  SEED_SANDBOX="$(_fixture_repository --seed-row "$SEED_ROW")"
  export SEED_SANDBOX
}

teardown_file() {
  if [ -n "${SEED_SANDBOX:-}" ]; then
    rm -rf "$SEED_SANDBOX"
  fi
}

setup() {
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  SOURCE_LIBRARY_DIRECTORY="$REPO_ROOT/.gaia/scripts/spec"
  [ -x "$SOURCE_LIBRARY_DIRECTORY/plan-reconcile.sh" ]
  SANDBOX=""
  _fresh_sandbox
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    rm -rf "$SANDBOX"
  fi
}

# Replaces $SANDBOX with a copy of the seeded fixture.
_fresh_sandbox() {
  [ -z "$SANDBOX" ] || rm -rf "$SANDBOX"
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  rm -rf "$SANDBOX"
  cp -R "$SEED_SANDBOX" "$SANDBOX"
}

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

# _gh_stub_that_fails: a gh on PATH that records its invocation and fails, so a
# test proves the single-id form never reaches the network.
_gh_stub_that_fails() {
  STUB_DIRECTORY="$BATS_TEST_TMPDIR/stub-fail"
  rm -rf "$STUB_DIRECTORY"
  mkdir -p "$STUB_DIRECTORY"
  printf '#!/usr/bin/env bash\necho invoked >> "%s/gh-called"\nexit 1\n' "$STUB_DIRECTORY" > "$STUB_DIRECTORY/gh"
  chmod +x "$STUB_DIRECTORY/gh"
  PATH="$STUB_DIRECTORY:$PATH"
}

_seed_scan_catalog() {
  jq '.items = [
    {"kind":"plan","id":"PLAN-031","path":"plans/PLAN-031","status":"ready","subject":"a","source":"allocated","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z"},
    {"kind":"plan","id":"PLAN-032","path":"plans/PLAN-032","status":"merged","subject":"b","source":"allocated","created_at":"2026-01-02T00:00:00Z","status_changed_at":"2026-02-01T00:00:00Z","merged_at":"2026-02-01T00:00:00Z"},
    {"kind":"plan","id":"PLAN-033","path":"plans/PLAN-033","status":"ready","subject":"c","source":"allocated","created_at":"2026-01-03T00:00:00Z","status_changed_at":"2026-01-03T00:00:00Z"},
    {"kind":"plan","id":"PLAN-034","path":"plans/PLAN-034","status":"merged","subject":"d","source":"allocated","created_at":"2026-01-04T00:00:00Z","status_changed_at":"2026-02-02T00:00:00Z","merged_at":"2026-02-02T00:00:00Z","pr_number":70}
  ]' "$SANDBOX/$CATALOG_RELATIVE_PATH" > "$BATS_TEST_TMPDIR/seeded-catalog.json"
  cp "$BATS_TEST_TMPDIR/seeded-catalog.json" "$SANDBOX/$CATALOG_RELATIVE_PATH"
}

# _seed_single_ready_plan <created_at>: the catalog holds one ready plan row created at that stamp.
_seed_single_ready_plan() {
  jq --arg created_at "$1" '.items = [{"kind":"plan","id":"PLAN-031","path":"plans/PLAN-031","status":"ready","subject":"a","source":"allocated","created_at":$created_at,"status_changed_at":$created_at}]' \
    "$SANDBOX/$CATALOG_RELATIVE_PATH" > "$BATS_TEST_TMPDIR/seeded-catalog.json"
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

@test "single-id form: flips a ready row to merged with an ISO merged_at and a pr_number only when valid, never over the network, and ignores unusable ids" {
  local before after id bad

  # Flips without a plan folder, never writes the retired "completed".
  [ ! -d "$SANDBOX/.notebook/plans/PLAN-005" ] || { echo "fixture holds a plan folder"; return 1; }
  run _reconcile PLAN-005
  [ "$status" -eq 0 ] || { echo "flip: status $status"; return 1; }
  grep -qF "reconciled PLAN-005 -> merged" <<<"$output" || { echo "flip: got '$output'"; return 1; }
  grep -qF -- "-> completed" <<<"$output" && { echo "flip: wrote completed"; return 1; }
  [ "$(_row_field PLAN-005 status)" = "merged" ] || { echo "flip: status not merged"; return 1; }
  case "$(_row_field PLAN-005 merged_at)" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) echo "flip: merged_at not ISO"; return 1 ;;
  esac

  # A second run re-stamps merged and exits 0.
  run _reconcile PLAN-005
  [ "$status" -eq 0 ] || { echo "second run: status $status"; return 1; }
  [ "$(_row_field PLAN-005 status)" = "merged" ] || { echo "second run: status not merged"; return 1; }

  # A non-plan id is a no-op.
  _fresh_sandbox
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  for id in cache-thing PLAN-x; do
    run _reconcile "$id"
    [ "$status" -eq 0 ] || { echo "id $id: status $status"; return 1; }
  done
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after" || { echo "non-plan ids changed the catalog"; return 1; }

  # A missing catalog exits 0 and creates nothing.
  _fresh_sandbox
  rm -f "$SANDBOX/$CATALOG_RELATIVE_PATH"
  run _reconcile PLAN-005
  [ "$status" -eq 0 ] || { echo "missing catalog: status $status"; return 1; }
  [ ! -f "$SANDBOX/$CATALOG_RELATIVE_PATH" ] || { echo "missing catalog: created one"; return 1; }

  # A missing row exits 0 and leaves the catalog unchanged.
  _fresh_sandbox
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  run _reconcile PLAN-999
  [ "$status" -eq 0 ] || { echo "missing row: status $status"; return 1; }
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after" || { echo "missing row changed the catalog"; return 1; }

  # A positive-integer third argument stamps pr_number as a JSON number with no network call.
  _fresh_sandbox
  _gh_stub_that_fails
  run _reconcile PLAN-005 2601
  [ "$status" -eq 0 ] || { echo "pr_number: status $status"; return 1; }
  grep -qF "reconciled PLAN-005 -> merged" <<<"$output" || { echo "pr_number: got '$output'"; return 1; }
  [ "$(_row_field PLAN-005 status)" = "merged" ] || { echo "pr_number: status not merged"; return 1; }
  jq -e '.items[] | select(.kind == "plan" and .id == "PLAN-005") | .pr_number == 2601' "$SANDBOX/$CATALOG_RELATIVE_PATH" >/dev/null || { echo "pr_number: not stamped as a number"; return 1; }
  [ ! -e "$STUB_DIRECTORY/gh-called" ] || { echo "pr_number: reached gh"; return 1; }

  # The two-argument form exits 0 for a valid, a malformed and an unknown id, stamps no pr_number, and reaches no network.
  _fresh_sandbox
  run --separate-stderr _reconcile PLAN-005
  [ "$status" -eq 0 ] || { echo "two-argument PLAN-005: status $status"; return 1; }
  [ "$output" = "reconciled PLAN-005 -> merged" ] || { echo "two-argument PLAN-005: stdout '$output'"; return 1; }
  [ -z "$stderr" ] || { echo "two-argument PLAN-005: stderr '$stderr'"; return 1; }
  for id in PLAN-x cache-thing; do
    run --separate-stderr _reconcile "$id"
    [ "$status" -eq 0 ] || { echo "two-argument $id: status $status"; return 1; }
    [ -z "$output" ] || { echo "two-argument $id: stdout '$output'"; return 1; }
    [ "$stderr" = "plan-reconcile: $id not PLAN-NNN; nothing to do" ] || { echo "two-argument $id: stderr '$stderr'"; return 1; }
  done
  run --separate-stderr _reconcile PLAN-999
  [ "$status" -eq 0 ] || { echo "two-argument PLAN-999: status $status"; return 1; }
  [ -z "$output" ] || { echo "two-argument PLAN-999: stdout '$output'"; return 1; }
  [[ "$stderr" == "plan-reconcile: could not advance PLAN-999"* ]] || { echo "two-argument PLAN-999: stderr '$stderr'"; return 1; }
  [ "$(_row_field PLAN-005 pr_number)" = "null" ] || { echo "two-argument: stamped pr_number"; return 1; }
  [ ! -e "$STUB_DIRECTORY/gh-called" ] || { echo "two-argument: reached gh"; return 1; }

  # A third argument that is not a PR number (a positive integer with no leading zero) stamps without pr_number and names the value on stderr.
  for bad in abc 0 007 -4 12x ""; do
    _fresh_sandbox
    run --separate-stderr _reconcile PLAN-005 "$bad"
    [ "$status" -eq 0 ] || { echo "bad '$bad': status $status"; return 1; }
    [ "$stderr" = "plan-reconcile: $bad is not a PR number; stamped without pr_number" ] || { echo "bad '$bad': stderr '$stderr'"; return 1; }
    grep -qF "reconciled PLAN-005 -> merged" <<<"$output" || { echo "bad '$bad': got '$output'"; return 1; }
    [ "$(_row_field PLAN-005 status)" = "merged" ] || { echo "bad '$bad': status not merged"; return 1; }
    [ "$(_row_field PLAN-005 pr_number)" = "null" ] || { echo "bad '$bad': stamped pr_number"; return 1; }
  done
}

@test "scan form: matches ready and pr_number-less merged rows to the newest merged PR naming the plan and leaves every other case byte-identical" {
  local before after bare tool tool_path expected_unmatched expected_confirmed

  # Matches the newest PR per plan; unmatched rows and rows with a pr_number stay as they were.
  _seed_scan_catalog
  _gh_stub_listing
  expected_unmatched="$(_row_json PLAN-033)"
  expected_confirmed="$(_row_json PLAN-034)"
  run _reconcile_scan
  [ "$status" -eq 0 ] || { echo "match: status $status"; return 1; }
  [ "$(_row_field PLAN-031 status)" = "merged" ] || { echo "match: PLAN-031 not merged"; return 1; }
  [ "$(_row_field PLAN-031 merged_at)" = "2026-03-05T00:00:00Z" ] || { echo "match: PLAN-031 merged_at"; return 1; }
  jq -e '.items[] | select(.kind == "plan" and .id == "PLAN-031") | .pr_number == 101' "$SANDBOX/$CATALOG_RELATIVE_PATH" >/dev/null || { echo "match: PLAN-031 pr_number"; return 1; }
  [ "$(_row_field PLAN-032 status)" = "merged" ] || { echo "match: PLAN-032 not merged"; return 1; }
  [ "$(_row_field PLAN-032 merged_at)" = "2026-03-02T00:00:00Z" ] || { echo "match: PLAN-032 merged_at"; return 1; }
  jq -e '.items[] | select(.kind == "plan" and .id == "PLAN-032") | .pr_number == 102' "$SANDBOX/$CATALOG_RELATIVE_PATH" >/dev/null || { echo "match: PLAN-032 pr_number"; return 1; }
  [ "$(_row_json PLAN-033)" = "$expected_unmatched" ] || { echo "match: unmatched row changed"; return 1; }
  [ "$(_row_json PLAN-034)" = "$expected_confirmed" ] || { echo "match: confirmed row changed"; return 1; }

  # A same-number PR merged before the row was created is ignored.
  _fresh_sandbox
  _seed_single_ready_plan "2026-03-10T00:00:00Z"
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  run _reconcile_scan
  [ "$status" -eq 0 ] || { echo "older PR: status $status"; return 1; }
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after" || { echo "older PR changed the catalog"; return 1; }
  [ "$(_row_field PLAN-031 status)" = "ready" ] || { echo "older PR: row not ready"; return 1; }

  # A same-number PR merged after the row was created still matches when an older one shares the number.
  _fresh_sandbox
  _seed_single_ready_plan "2026-03-03T00:00:00Z"
  run _reconcile_scan
  [ "$status" -eq 0 ] || { echo "newer PR: status $status"; return 1; }
  [ "$(_row_field PLAN-031 status)" = "merged" ] || { echo "newer PR: row not merged"; return 1; }
  jq -e '.items[] | select(.kind == "plan" and .id == "PLAN-031") | .pr_number == 101' "$SANDBOX/$CATALOG_RELATIVE_PATH" >/dev/null || { echo "newer PR: pr_number"; return 1; }

  # No gh on PATH: the catalog is byte-identical and the exit is 0.
  _fresh_sandbox
  _seed_scan_catalog
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  bare="$BATS_TEST_TMPDIR/bare-bin"
  mkdir -p "$bare"
  for tool in bash jq git sed sort tail date cat dirname basename mkdir rm mv grep awk tr head cut wc uname env mktemp; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [ -z "$tool_path" ] || ln -sf "$tool_path" "$bare/$tool"
  done
  PATH="$bare" run bash "$SANDBOX/.gaia/scripts/spec/plan-reconcile.sh" "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "no gh: status $status"; return 1; }
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after" || { echo "no gh changed the catalog"; return 1; }

  # A failing gh: the catalog is byte-identical and the exit is 0.
  _fresh_sandbox
  _seed_scan_catalog
  _gh_stub_that_fails
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  run _reconcile_scan
  [ "$status" -eq 0 ] || { echo "failing gh: status $status"; return 1; }
  [ -e "$STUB_DIRECTORY/gh-called" ] || { echo "failing gh: gh never called"; return 1; }
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after" || { echo "failing gh changed the catalog"; return 1; }
}

@test "a zero-argument call prints the usage line naming both forms and exits 0" {
  run --separate-stderr bash "$SANDBOX/.gaia/scripts/spec/plan-reconcile.sh"
  [ "$status" -eq 0 ]
  grep -qF "usage: plan-reconcile.sh <repo_root> [<plan_id> [<pr_number>]]" <<<"$stderr"
}

@test "when the one-time move is pending both forms print the move line on stderr, exit 0 and change nothing" {
  local before after

  rm -rf "$SANDBOX"
  SANDBOX="$(_fixture_repository --legacy \
    --seed-row '{"kind":"plan","id":"PLAN-005","path":"plans/PLAN-005","status":"ready","subject":"x","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z"}')"
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  run --separate-stderr _reconcile PLAN-005 2601
  [ "$status" -eq 0 ] || { echo "single-id: status $status"; return 1; }
  [ -z "$output" ] || { echo "single-id: stdout '$output'"; return 1; }
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$stderr" || { echo "single-id: stderr '$stderr'"; return 1; }
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after" || { echo "single-id changed the catalog"; return 1; }
  [ "$(_row_field PLAN-005 status)" = "ready" ] || { echo "single-id: row not ready"; return 1; }

  rm -rf "$SANDBOX"
  SANDBOX="$(_fixture_repository --legacy \
    --seed-row '{"kind":"plan","id":"PLAN-031","path":"plans/PLAN-031","status":"ready","subject":"a","created_at":"2026-01-01T00:00:00Z","status_changed_at":"2026-01-01T00:00:00Z"}')"
  _gh_stub_listing
  before="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  run --separate-stderr _reconcile_scan
  [ "$status" -eq 0 ] || { echo "scan: status $status"; return 1; }
  [ -z "$output" ] || { echo "scan: stdout '$output'"; return 1; }
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$stderr" || { echo "scan: stderr '$stderr'"; return 1; }
  after="$(snapshot_file "$SANDBOX/$CATALOG_RELATIVE_PATH")"
  assert_files_identical "$before" "$after" || { echo "scan changed the catalog"; return 1; }
  [ "$(_row_field PLAN-031 status)" = "ready" ] || { echo "scan: row not ready"; return 1; }
}

@test "run from the real repo root, the scan acts on the operand's fixture only" {
  _seed_scan_catalog
  _gh_stub_listing
  real_before="$(directory_listing_checksum "$REPO_ROOT/.notebook")"
  run bash -c 'cd "$1" && bash "$2/.gaia/scripts/spec/plan-reconcile.sh" "$2"' _ "$REPO_ROOT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(_row_field PLAN-031 status)" = "merged" ]
  real_after="$(directory_listing_checksum "$REPO_ROOT/.notebook")"
  [ "$real_after" = "$real_before" ]
}
