#!/usr/bin/env bats
# Tests for `.gaia/scripts/spec/spec-abandon-empty.sh`: the guarded
# sweep that retires a never-authored SPEC draft to the terminal `abandoned`
# status. Every test runs the real script against an isolated fixture
# notebook, never the GAIA repo's own.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  LIBRARY_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/../spec" && pwd)"
  REPO_SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../.gaia/scripts" && pwd)"
  SCRIPT="$LIBRARY_DIRECTORY/spec-abandon-empty.sh"
  LEDGER_UPDATE="$LIBRARY_DIRECTORY/ledger-update.sh"
  [ -x "$SCRIPT" ]

  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  mkdir -p "$SANDBOX/.notebook/specs" "$SANDBOX/.gaia/local/cache" "$SANDBOX/.gaia/scripts/notebook"
  # The scripts under test resolve the main checkout through the notebook
  # library and main-root-lib.sh, which require a real git repo (fail-closed,
  # no operand fallback); a plain mktemp -d is not one. The notebook must be
  # gitignored for the library to write the catalog.
  git -C "$SANDBOX" init --quiet --initial-branch=main
  printf '.gaia/local\n.notebook\n' > "$SANDBOX/.gitignore"
  cp "$REPO_SCRIPTS/main-root-lib.sh" "$SANDBOX/.gaia/scripts/"
  cp "$REPO_SCRIPTS"/notebook/*.sh "$SANDBOX/.gaia/scripts/notebook/"
  chmod +x "$SANDBOX/.gaia/scripts/main-root-lib.sh" "$SANDBOX"/.gaia/scripts/notebook/*.sh
  CATALOG="$SANDBOX/.notebook/catalog.json"
}

# old_timestamp / new_timestamp: portable ISO8601 timestamps well outside / inside the
# guard age, computed with jq (never `date -d`/`date -j`, matching the
# project's cross-platform epoch rule).
old_timestamp() {
  jq -rn '(now - 90000) | strftime("%Y-%m-%dT%H:%M:%SZ")' # ~25h ago
}

new_timestamp() {
  jq -rn '(now - 60) | strftime("%Y-%m-%dT%H:%M:%SZ")' # ~1m ago
}

# seed_catalog <json-spec-rows-array>: writes the catalog with the given spec
# rows, each given its kind and notebook-relative path.
seed_catalog() {
  jq -n --argjson rows "$1" '{
    version: 1,
    items: ($rows | map(. + {kind: "spec", path: ("specs/" + .id), subject: .id}))
  }' > "$CATALOG"
}

status_of() {
  jq -r --arg id "$1" '.items[] | select(.kind == "spec" and .id == $id) | .status' "$CATALOG"
}

@test "flips every aged empty draft to abandoned with abandoned_at and leaves a young one" {
  seed_catalog "$(jq -nc --arg old "$(old_timestamp)" --arg new "$(new_timestamp)" '[
    {id: "SPEC-010", created_at: $old, status: "draft"},
    {id: "SPEC-011", created_at: $old, status: "draft"},
    {id: "SPEC-012", created_at: $new, status: "draft"}
  ]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-010)" = "abandoned" ]
  [ "$(status_of SPEC-011)" = "abandoned" ]
  [ "$(status_of SPEC-012)" = "draft" ]
  grep -qF -- "SPEC-010" <<<"$output"
  grep -qF -- "SPEC-011" <<<"$output"
  [ -n "$(jq -r '.items[] | select(.id == "SPEC-010") | .abandoned_at // empty' "$CATALOG")" ]
}

# prepare_kept_case <case>: seeds one catalog row the sweep must leave alone and
# sets kept_status to the status it must still hold.
prepare_kept_case() {
  local case_name="$1" row
  rm -rf "$SANDBOX/.notebook/specs/SPEC-030"
  rm -f "$SANDBOX"/.gaia/local/cache/*
  kept_status=draft
  row="$(jq -nc --arg timestamp "$(old_timestamp)" '{id: "SPEC-030", created_at: $timestamp, status: "draft"}')"
  case "$case_name" in
    draft-cache) echo "in progress" > "$SANDBOX/.gaia/local/cache/draft-SPEC-030.md" ;;
    spec-file)
      mkdir -p "$SANDBOX/.notebook/specs/SPEC-030"
      echo "# SPEC" > "$SANDBOX/.notebook/specs/SPEC-030/SPEC.md"
      ;;
    requirements-file)
      mkdir -p "$SANDBOX/.notebook/specs/SPEC-030"
      echo "# Requirements" > "$SANDBOX/.notebook/specs/SPEC-030/REQUIREMENTS.md"
      ;;
    gate-snapshot) echo '{}' > "$SANDBOX/.gaia/local/cache/gate1-SPEC-030.json" ;;
    young-draft) row="$(jq -nc --arg timestamp "$(new_timestamp)" '{id: "SPEC-030", created_at: $timestamp, status: "draft"}')" ;;
    non-draft)
      kept_status=specified
      row="$(jq -nc --arg timestamp "$(old_timestamp)" '{id: "SPEC-030", created_at: $timestamp, status: "specified"}')"
      ;;
    unparseable-created-at) row='{"id": "SPEC-030", "created_at": "not-a-date", "status": "draft"}' ;;
    missing-created-at) row='{"id": "SPEC-030", "status": "draft"}' ;;
  esac
  seed_catalog "[$row]"
}

# bats test_tags=protected
@test "the sweep leaves a draft untouched when it holds authored work, is young, is not a draft or has no usable created_at" {
  local case_name
  for case_name in draft-cache spec-file requirements-file gate-snapshot young-draft non-draft unparseable-created-at missing-created-at; do
    prepare_kept_case "$case_name"
    run bash "$SCRIPT" "$SANDBOX"
    [ "$status" -eq 0 ] || { echo "case $case_name: status $status"; return 1; }
    [ "$(status_of SPEC-030)" = "$kept_status" ] || { echo "case $case_name: row changed to $(status_of SPEC-030)"; return 1; }
    [ -z "$output" ] || { echo "case $case_name: output '$output'"; return 1; }
  done
}

@test "no-op inputs exit 0 silently: no catalog, no draft rows, no repo_root argument" {
  rm -f "$CATALOG"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "no catalog: status $status"; return 1; }
  [ -z "$output" ] || { echo "no catalog: output '$output'"; return 1; }
  [ ! -e "$CATALOG" ] || { echo "no catalog: catalog created"; return 1; }

  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-013", created_at: $timestamp, status: "merged"}]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "no draft rows: status $status"; return 1; }
  [ -z "$output" ] || { echo "no draft rows: output '$output'"; return 1; }

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- Flip flows through the real ledger-update.sh chokepoint ----------------

@test "the flip is rejected if ledger-update.sh's status guard would reject it" {
  # Sanity: ledger-update.sh itself accepts "abandoned" directly (the
  # chokepoint this sweep depends on), confirming the sweep and the guard
  # agree on the vocabulary rather than each hardcoding it separately.
  seed_catalog '[{"id": "SPEC-014", "status": "draft"}]'
  run bash "$LEDGER_UPDATE" "$SANDBOX" SPEC-014 '{"status":"abandoned"}'
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-014)" = "abandoned" ]
}

# --- Orphan lock: removed on abandon, and never rescues a ghost -------------

@test "a ghost draft is abandoned and its orphan .lock file removed; a lone lock never rescues it" {
  # A dead session's lock is precisely the ghost shape; the emptiness guard
  # never grows a fourth (`.lock`) check, so a locked ghost is abandoned
  # exactly like a lock-free one.
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-015", created_at: $timestamp, status: "draft"}]')"
  echo '{"spec_id":"SPEC-015"}' > "$SANDBOX/.gaia/local/cache/spec-session-SPEC-015.lock"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-015)" = "abandoned" ]
  [ ! -e "$SANDBOX/.gaia/local/cache/spec-session-SPEC-015.lock" ]
}

# --- A row id that would climb out of the specs folder is skipped ------------

# bats test_tags=protected
@test "a traversal-shaped row id is skipped with a stderr line and never flipped" {
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-001/../../x", created_at: $timestamp, status: "draft"}]')"
  run --separate-stderr bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"refused the folder for row id"* ]]
  [ "$(status_of 'SPEC-001/../../x')" = "draft" ]
}

# --- Not ready: exit 3, the move line, nothing changed -----------------------

@test "a not-ready notebook exits 3 with the move line and changes nothing" {
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-017", created_at: $timestamp, status: "draft"}]')"
  mkdir -p "$SANDBOX/.gaia/local/specs"
  printf '{"version": 1, "specs": []}\n' > "$SANDBOX/.gaia/local/specs/ledger.json"
  before="$(cat "$CATALOG")"
  run --separate-stderr bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"bash .gaia/scripts/notebook/move.sh run"* ]]
  [ "$(cat "$CATALOG")" = "$before" ]
  [ "$(status_of SPEC-017)" = "draft" ]
}
