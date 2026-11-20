#!/usr/bin/env bats
# Tests for `.gaia/scripts/spec/spec-reconcile.sh` (the spec arm; see
# plan-reconcile.bats for the plan arm). Uses helpers/tmp-notebook-repo.sh, which
# already copies spec-reconcile.sh + ledger-update.sh + the notebook library
# into a real tmp git repo so ${BASH_SOURCE[0]}-relative sourcing resolves and
# `git -C <repo> rev-parse --git-dir` succeeds. The "ready" row these tests
# need (the candidate status the finalize transition writes) is seeded with
# --seed-spec SPEC-006 ready.

bats_require_minimum_version 1.5.0

# Builds the throwaway fixture repository the suite acts on.
_fixture_repository() {
  "$HELPERS/tmp-notebook-repo.sh" "$@"
}

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$BATS_TEST_DIRNAME/../helpers/files.sh"
  . "$BATS_TEST_DIRNAME/../helpers/path.sh"
  RECONCILE=".gaia/scripts/spec/spec-reconcile.sh"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
  if [ -n "${STUB_DIRECTORY:-}" ]; then
    rm -rf "$STUB_DIRECTORY"
  fi
}

_catalog() {
  printf '%s\n' "$REPO/.notebook/catalog.json"
}

_status_of() {
  jq -r --arg id "$1" '.items[] | select(.kind == "spec" and .id == $id) | .status' "$(_catalog)"
}

# Builds a `gh` stub on a temp PATH prefix that unconditionally echoes $1 to
# stdout (spec-reconcile.sh invokes gh in exactly one shape: `gh pr list
# --state merged --limit 200 --json number,headRefName,mergedAt`).
_stub_gh_echoing() {
  local body="$1"
  STUB_DIRECTORY="$(mktemp -d)"
  cat > "$STUB_DIRECTORY/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$body'
EOF
  chmod +x "$STUB_DIRECTORY/gh"
}

# Builds a `gh` stub that exits 0 with no stdout (the "gh returns empty" fail-
# open case, distinct from gh being altogether absent from PATH).
_stub_gh_empty() {
  STUB_DIRECTORY="$(mktemp -d)"
  cat > "$STUB_DIRECTORY/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB_DIRECTORY/gh"
}

# A PATH with every tool spec-reconcile.sh (and its ledger-update.sh /
# with-ledger-lock.sh deps) actually invokes, symlinked in from the real
# PATH, but with no `gh` anywhere on it.
_no_gh_path() {
  NO_GH_PATH="$(path_allowlist bash jq git sed mktemp mv rm mkdir rmdir stat date sleep)"
}

# --- the merge match: head-branch spelling, latest merge, other branches ------
@test "a merged PR on a plan branch flips a ready SPEC to merged by head-branch spelling, latest merge wins, other branches no-op" {
  # One seeded repo, copied per case. Columns: label, the gh stub's JSON, the
  # expected status, the expected reconciled line, and the expected merged_at
  # (absent when the row must not carry one). A dash skips that assertion.
  base="$(_fixture_repository --seed-spec SPEC-006 ready)"
  local label body expected_status reconciled_line expected_merged_at
  while IFS='|' read -r label body expected_status reconciled_line expected_merged_at; do
    echo "case: $label"
    rm -rf "$REPO" "$STUB_DIRECTORY"
    REPO="$BATS_TEST_TMPDIR/case"
    cp -R "$base" "$REPO"
    _stub_gh_echoing "$body"

    run bash -c "PATH='$STUB_DIRECTORY:$PATH' bash '$REPO/$RECONCILE' '$REPO'"
    [ "$status" -eq 0 ]
    [ "$(_status_of SPEC-006)" = "$expected_status" ]
    if [ "$reconciled_line" != - ]; then
      grep -qF "$reconciled_line" <<<"$output"
    fi
    case "$expected_merged_at" in
      -) ;;
      absent) [ "$(jq -r '.items[] | select(.kind=="spec" and .id=="SPEC-006") | has("merged_at")' "$(_catalog)")" = "false" ] ;;
      *) [ "$(jq -r '.items[] | select(.kind=="spec" and .id=="SPEC-006") | .merged_at' "$(_catalog)")" = "$expected_merged_at" ] ;;
    esac
  done <<'CASES'
gh returns a merged PR on plan/spec-006-*; SPEC-006 flips to merged|[{"number":42,"headRefName":"plan/spec-006-x","mergedAt":"2026-05-01T00:00:00Z"}]|merged|reconciled SPEC-006 -> merged (PR #42, 2026-05-01T00:00:00Z)|2026-05-01T00:00:00Z
a worktree-spelled head branch matches, and the latest of two merges wins|[{"number":40,"headRefName":"plan/spec-006-first","mergedAt":"2026-04-01T00:00:00Z"},{"number":43,"headRefName":"worktree-plan+spec-006-x","mergedAt":"2026-05-02T00:00:00Z"}]|merged|reconciled SPEC-006 -> merged (PR #43, 2026-05-02T00:00:00Z)|-
no PR names SPEC-006 in a minted spelling (another SPEC, the retired unprefixed spelling); stays ready|[{"number":7,"headRefName":"plan/spec-999-other","mergedAt":"2026-05-01T00:00:00Z"},{"number":8,"headRefName":"spec-006-legacy","mergedAt":"2026-05-01T00:00:00Z"}]|ready|-|absent
CASES
  rm -rf "$base"
}

# --- fail-open: no gh on PATH, or gh present but returns empty ----------------
@test "gh absent or empty leaves the catalog unchanged with exit 0" {
  # Neither case writes, so both run against the one repo.
  REPO="$(_fixture_repository --seed-spec SPEC-006 ready)"
  before="$(snapshot_file "$(_catalog)")"

  echo "case: gh absent from PATH"
  _no_gh_path
  run bash -c "PATH='$NO_GH_PATH' bash '$REPO/$RECONCILE' '$REPO'"
  [ "$status" -eq 0 ]
  after="$(snapshot_file "$(_catalog)")"
  assert_files_identical "$before" "$after"

  echo "case: gh present but returns empty output"
  _stub_gh_empty
  run bash -c "PATH='$STUB_DIRECTORY:$PATH' bash '$REPO/$RECONCILE' '$REPO'"
  [ "$status" -eq 0 ]
  after="$(snapshot_file "$(_catalog)")"
  assert_files_identical "$before" "$after"
}

@test "9: a retired 'specified' row is not a merge candidate; logged unrecognized, left as-is" {
  REPO="$(_fixture_repository --seed-spec SPEC-006 specified)"
  # A matching merged PR exists, but a "specified" row is off-vocabulary now
  # (the finalize state migrated to "ready"), so it is never reached as a
  # candidate; the off-vocab normalizer logs it as unrecognized instead.
  _stub_gh_echoing '[{"number":42,"headRefName":"plan/spec-006-x","mergedAt":"2026-05-01T00:00:00Z"}]'

  run bash -c "PATH='$STUB_DIRECTORY:$PATH' bash '$REPO/$RECONCILE' '$REPO'"
  [ "$status" -eq 0 ]
  grep -qF "unrecognized status specified" <<<"$output"
  [ "$(_status_of SPEC-006)" = "specified" ]
}

# --- 10: not ready ------------------------------------------------------------

@test "10: a not-ready notebook prints the move line, changes nothing and exits 0" {
  REPO="$(_fixture_repository --legacy --seed-spec SPEC-006 ready)"
  _stub_gh_echoing '[{"number":42,"headRefName":"plan/spec-006-x","mergedAt":"2026-05-01T00:00:00Z"}]'
  before="$(snapshot_file "$(_catalog)")"

  run --separate-stderr bash -c "PATH='$STUB_DIRECTORY:$PATH' bash '$REPO/$RECONCILE' '$REPO'"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"bash .gaia/scripts/notebook/move.sh run"* ]]
  [[ "$output" != *"reconciled"* ]]
  after="$(snapshot_file "$(_catalog)")"
  assert_files_identical "$before" "$after"
  [ "$(_status_of SPEC-006)" = "ready" ]
}

# --- 11: tree selector ----------------------------------------------------------

@test "11: run from the real repo's cwd with a fixture operand, only the fixture's catalog changes" {
  REPO="$(_fixture_repository --seed-spec SPEC-006 ready)"
  _stub_gh_echoing '[{"number":42,"headRefName":"plan/spec-006-x","mergedAt":"2026-05-01T00:00:00Z"}]'
  real_repo="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  real_before="$(directory_listing_checksum "$real_repo/.notebook")"

  run bash -c "cd '$real_repo' && PATH='$STUB_DIRECTORY:$PATH' bash '$REPO/$RECONCILE' '$REPO'"
  [ "$status" -eq 0 ]
  [ "$(_status_of SPEC-006)" = "merged" ]
  [ "$(directory_listing_checksum "$real_repo/.notebook")" = "$real_before" ]
}
