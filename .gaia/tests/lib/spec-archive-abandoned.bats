#!/usr/bin/env bats
# Delete-sweep tests for spec-archive-abandoned.sh, the abandoned-status
# counterpart to spec-archive-merged.sh (see that script's own suite,
# spec-archive-merged.bats, for the merged path this mirrors).
#
# Unlike the merged sweep there is no usage-ledger gate: an abandoned draft
# never closes a run, so the age rule alone decides. Tests prove it with a
# usage.sh stub that logs any invocation.
#
# Sweep criteria: a catalog row with status "abandoned" and no reap record AND
# a folder AND abandoned_at past the retention window. A successful delete
# records a reap on the row. Unlike the merged sweep there is
# no consolidation gate: an abandoned folder reaps as one unit.
#
# Each test spins up its own tmp git repo via helpers/tmp-notebook-repo.sh and
# tears it down; hermetic, no reliance on the real project notebook.
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  ARCHIVE=".gaia/scripts/spec/spec-archive-abandoned.sh"
  SPECS=".notebook/specs"
  USAGE_LEDGER=".gaia/local/telemetry/usage.jsonl"
  # --seed-spec-abandoned-folder stamps a fixed abandoned_at
  # ("2026-01-01T00:00:00Z") rather than "just abandoned", so every delete
  # test below needs the age gate collapsed to stay deterministic regardless
  # of wall-clock time. The age-gate tests re-export this per test.
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

_snapshot() {
  ( cd "$REPO/$SPECS" 2>/dev/null \
      && find . -type f -print0 2>/dev/null \
         | sort -z \
         | xargs -0 shasum 2>/dev/null ) || true
}

_days_ago() {
  jq -rn --argjson days "$1" '(now - ($days * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# _set_abandoned_at <repo> <spec_id> <iso>: patches the seeded ledger row's
# abandoned_at, for tests that need a specific age instead of the fixture's
# fixed date.
_set_abandoned_at() {
  local repo="$1" id="$2" iso="$3"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" --arg timestamp "$iso" \
    '.items |= map(if .kind == "spec" and .id == $id then . + {abandoned_at: $timestamp} else . end)' \
    "$repo/.notebook/catalog.json" > "$temporary_file"
  mv "$temporary_file" "$repo/.notebook/catalog.json"
}

_clear_abandoned_at() {
  local repo="$1" id="$2"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" \
    '.items |= map(if .kind == "spec" and .id == $id then del(.abandoned_at) else . end)' \
    "$repo/.notebook/catalog.json" > "$temporary_file"
  mv "$temporary_file" "$repo/.notebook/catalog.json"
}

# --- 1: delete happy path (age rule alone) ----------------------------------

@test "1: an abandoned row past the retention window is deleted; the row stays abandoned" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/archived" ]

  [ "$(jq -r '.items[0].status' "$REPO/.notebook/catalog.json")" = "abandoned" ]
  [ "$(jq -r '.items[0].abandoned_at' "$REPO/.notebook/catalog.json")" = "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.items[0].reap.by' "$REPO/.notebook/catalog.json")" = "spec-archive-abandoned.sh" ]
  jq -e '.items[0].reap.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$REPO/.notebook/catalog.json"
}

# bats test_tags=protected
@test "abandoned sweep touches only abandoned rows with a folder and no reap record" {
  # One repo holds every selection case: SPEC-001 is the only reapable row.
  # SPEC-004 already carries a reap record, SPEC-005 has no folder, SPEC-002
  # is merged and SPEC-003 is a draft.
  REPO="$("$HELPERS/tmp-notebook-repo.sh" \
    --seed-spec-abandoned-folder SPEC-001 --seed-spec-abandoned-folder SPEC-004 \
    --seed-spec SPEC-005 abandoned --seed-spec-merged-folder SPEC-002 \
    --seed-spec-folder SPEC-003 draft)"
  patched="$(mktemp)"
  jq '.items |= map(if .id == "SPEC-004" then . + {reap: {at: "2026-02-01T00:00:00Z", by: "spec-archive-abandoned.sh"}} else . end)' \
    "$REPO/.notebook/catalog.json" > "$patched"
  mv "$patched" "$REPO/.notebook/catalog.json"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  grep -qxF "Deleted 1 abandoned SPEC folder(s): SPEC-001" <<<"$output"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  echo "case: a row with a reap record is skipped"
  [ -f "$REPO/$SPECS/SPEC-004/AUDIT.md" ]
  echo "case: a merged row is never touched"
  [ -f "$REPO/$SPECS/SPEC-002/SPEC.md" ]
  echo "case: a folder without an abandoned row is never deleted"
  [ -f "$REPO/$SPECS/SPEC-003/SPEC.md" ]

  echo "case: re-running the sweep after deleting is a no-op"
  before="$(_snapshot)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  after="$(_snapshot)"
  [ "$before" = "$after" ]

  echo "case: a repo with no abandoned rows produces no output and exits 0"
  rm -rf "$REPO"
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 2: single-id form ---------------------------------------------------------

# bats test_tags=protected
@test "2: the single-id form deletes only the named id" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" \
    --seed-spec-abandoned-folder SPEC-001 --seed-spec-abandoned-folder SPEC-002)"

  run bash "$REPO/$ARCHIVE" "$REPO" SPEC-001
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ -d "$REPO/$SPECS/SPEC-002" ]
}

# --- 8: multiple abandoned folders in one sweep --------------------------------

@test "8: two abandoned folders are deleted together with a combined summary" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" \
    --seed-spec-abandoned-folder SPEC-001 --seed-spec-abandoned-folder SPEC-002)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 2 abandoned SPEC folder(s): SPEC-001, SPEC-002"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/SPEC-002" ]
}

# --- the retention window and the abandoned_at rule ---------------------------

# bats test_tags=protected
@test "abandoned sweep retention window and abandoned_at rule" {
  # One seeded repo, copied per case. Columns: label, GAIA_SPEC_RETENTION_DAYS,
  # abandoned_at (days:<n> ago, none to drop it, or a raw value), outcome,
  # and whether the keep line is asserted.
  base="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  REPO="$BATS_TEST_TMPDIR/case"
  local label retention stamp outcome keep_line
  while IFS='|' read -r label retention stamp outcome keep_line; do
    echo "case: $label"
    rm -rf "$REPO"
    cp -R "$base" "$REPO"
    case "$stamp" in
      none) _clear_abandoned_at "$REPO" SPEC-001 ;;
      days:*) _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago "${stamp#days:}")" ;;
      *) _set_abandoned_at "$REPO" SPEC-001 "$stamp" ;;
    esac
    export GAIA_SPEC_RETENTION_DAYS="$retention"

    run _archive "$REPO"
    [ "$status" -eq 0 ]
    if [ "$outcome" = reaped ]; then
      assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"
      [ ! -e "$REPO/$SPECS/SPEC-001" ]
      [ "$(jq -r '.items[0].status' "$REPO/.notebook/catalog.json")" = "abandoned" ]
    else
      refute_contains "Deleted"
      [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
      if [ "$keep_line" = yes ]; then
        assert_contains "SPEC-001 within retention window (or abandoned_at missing/unparseable); kept"
      fi
    fi
  done <<'CASES'
within the retention window is kept|30|days:2|kept|yes
past the retention window is reaped|30|days:45|reaped|no
no abandoned_at is kept regardless of the usage ledger|0|none|kept|yes
an unparseable abandoned_at is kept regardless of the usage ledger|0|not-a-timestamp|kept|yes
GAIA_SPEC_RETENTION_DAYS=0 reaps a just-abandoned folder|0|days:0|reaped|no
GAIA_SPEC_RETENTION_DAYS=99999 keeps an old abandoned folder|99999|days:400|kept|no
a non-numeric GAIA_SPEC_RETENTION_DAYS keeps a 10-day-old folder under the 30-day default|abc|days:10|kept|no
a non-numeric GAIA_SPEC_RETENTION_DAYS reaps a 45-day-old folder under the 30-day default|abc|days:45|reaped|no
CASES
  rm -rf "$base"
}

# --- 19: no consolidation gate -- a bare AUDIT.md folder still reaps -----------

@test "19: an abandoned folder holding only AUDIT.md reaps with no consolidation gate" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
  [ ! -e "$REPO/$SPECS/SPEC-001/SUMMARY.md" ]

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

# --- 20: the retired defer cache path is left alone --------------------------

# bats test_tags=protected
@test "20: reaping an abandoned row leaves a leftover wiki-promote cache file untouched" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  mkdir -p "$REPO/.gaia/local/cache/wiki-promote"
  printf '{"branch":"spec-1-x","deferred_at":"2026-01-02T00:00:00Z"}\n' \
    > "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  # The cache is retired: nothing reads it and nothing here purges it.
  [ -f "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json" ]
}

# --- 22: the liveness lock is reaped with the rest of the abandoned keyset ---

@test "22: a .lock file is reaped alongside the deleted abandoned folder" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  echo '{"spec_id":"SPEC-001"}' > "$REPO/.gaia/local/cache/spec-session-SPEC-001.lock"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/.gaia/local/cache/spec-session-SPEC-001.lock" ]
}

# bats test_tags=protected
@test "23: without ledger-lib.sh the sweep reaps nothing and says so; with it the same folder is reaped" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"

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

@test "24: an abandoned folder past retention is deleted on age alone and usage.sh is never called" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001 --seed-spec-abandoned-folder SPEC-002)"
  # A usage.sh stub that logs any invocation; the usage ledger is also absent,
  # which would keep the folder under the merged sweep's gate.
  rm -f "$REPO/$USAGE_LEDGER"
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"\$*\" >> \"$REPO/usage-calls.log\""
    echo 'exit 1'
  } > "$REPO/.gaia/scripts/usage.sh"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 2 abandoned SPEC folder(s): SPEC-001, SPEC-002"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/SPEC-002" ]
  [ ! -e "$REPO/usage-calls.log" ]
}
