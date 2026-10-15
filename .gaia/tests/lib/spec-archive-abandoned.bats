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

@test "1b: a row that already carries a reap record is skipped, even with a folder present" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  patched="$(mktemp)"
  jq '.items |= map(. + {reap: {at: "2026-02-01T00:00:00Z", by: "spec-archive-abandoned.sh"}})' "$REPO/.notebook/catalog.json" > "$patched"
  mv "$patched" "$REPO/.notebook/catalog.json"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}

# --- 2: single-id form ---------------------------------------------------------

@test "2: the single-id form deletes only the named id" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" \
    --seed-spec-abandoned-folder SPEC-001 --seed-spec-abandoned-folder SPEC-002)"

  run bash "$REPO/$ARCHIVE" "$REPO" SPEC-001
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ -d "$REPO/$SPECS/SPEC-002" ]
}

@test "4: an abandoned row with no active folder is a no-op" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-005 abandoned)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
}

# --- 5: idempotent re-run -------------------------------------------------------

@test "5: re-running the sweep after deleting is a no-op" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"

  before="$(_snapshot)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  after="$(_snapshot)"
  [ "$before" = "$after" ]
}

# --- 6: only abandoned rows with folders are swept; merged rows are untouched -

@test "6: a merged row is never touched by the abandoned sweep" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" \
    --seed-spec-abandoned-folder SPEC-001 --seed-spec-merged-folder SPEC-002)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  # SPEC-002 (merged) untouched: still active, never deleted by this script.
  [ -f "$REPO/$SPECS/SPEC-002/SPEC.md" ]
}


@test "7: a folder without an abandoned ledger row is never deleted" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001 --seed-spec-folder SPEC-002 draft)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ -f "$REPO/$SPECS/SPEC-002/SPEC.md" ]
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

# --- 9: no ledger -> clean no-op -------------------------------------------------

@test "9: a repo with no abandoned rows produces no output and exits 0" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 10: age gate, within window -> kept -----------------------------------------

@test "10: an abandoned folder within the retention window is kept, not deleted" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 2)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "SPEC-001 within retention window (or abandoned_at missing/unparseable); kept"

  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}


@test "11: an abandoned folder past the retention window is reaped" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]

  [ "$(jq -r '.items[0].status' "$REPO/.notebook/catalog.json")" = "abandoned" ]
}


# --- 13/14: missing or unparseable abandoned_at -> kept regardless of age --------

@test "13: an abandoned row with no abandoned_at is kept regardless of the usage ledger" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  _clear_abandoned_at "$REPO" SPEC-001
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "SPEC-001 within retention window (or abandoned_at missing/unparseable); kept"

  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}

@test "14: an abandoned row with an unparseable abandoned_at is kept regardless of the usage ledger" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "not-a-timestamp"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "SPEC-001 within retention window (or abandoned_at missing/unparseable); kept"

  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}

# --- 15/16: GAIA_SPEC_RETENTION_DAYS knob is honored, shared with the merged sweep

@test "15: GAIA_SPEC_RETENTION_DAYS=0 reaps a just-abandoned folder" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 0)"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

@test "16: GAIA_SPEC_RETENTION_DAYS=99999 keeps an old abandoned folder" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 400)"
  export GAIA_SPEC_RETENTION_DAYS=99999

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"

  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}


@test "17: a non-numeric GAIA_SPEC_RETENTION_DAYS falls back to the 30-day default" {
  export GAIA_SPEC_RETENTION_DAYS="abc"

  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 10)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$REPO/$SPECS/SPEC-001" ]

  REPO2="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-002)"
  _set_abandoned_at "$REPO2" SPEC-002 "$(_days_ago 45)"
  run bash "$REPO2/$ARCHIVE" "$REPO2"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-002"
  rm -rf "$REPO2"
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

@test "25: the stub in case 24 is live: the merged sweep, which does gate, calls it" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001)"
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"\$*\" >> \"$REPO/usage-calls.log\""
    echo 'exit 1'
  } > "$REPO/.gaia/scripts/usage.sh"

  run bash "$REPO/.gaia/scripts/spec/spec-archive-merged.sh" "$REPO"
  [ "$status" -eq 0 ]
  [ -s "$REPO/usage-calls.log" ]
  grep -qF "represented spec:SPEC-001 --workflow gaia-spec" "$REPO/usage-calls.log"
}

@test "26: the sweep's executable lines name no usage.sh call and no represented gate" {
  non_comment="$(grep -v '^[[:space:]]*#' "$BATS_TEST_DIRNAME/../../scripts/spec/spec-archive-abandoned.sh")"
  [ -n "$non_comment" ]
  grep -qE 'usage\.sh|represented' <<<"$non_comment" && return 1
  true
}
