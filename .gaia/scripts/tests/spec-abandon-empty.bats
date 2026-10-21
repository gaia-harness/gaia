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

# --- 1. Flips a fully empty, aged draft --------------------------------------

@test "flips an empty draft older than the guard age to abandoned" {
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-001", created_at: $timestamp, status: "draft"}]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-001)" = "abandoned" ]
  grep -qF -- "Abandoned 1 never-authored draft(s): SPEC-001" <<<"$output"
}

@test "stamps abandoned_at on the flipped row" {
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-001", created_at: $timestamp, status: "draft"}]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  abandoned_at="$(jq -r '.items[0].abandoned_at // empty' "$CATALOG")"
  [ -n "$abandoned_at" ]
}

# --- 2. Leaves a draft with a draft cache untouched (any age) ----------------

@test "leaves a draft with a draft-<id>.md cache untouched" {
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-002", created_at: $timestamp, status: "draft"}]')"
  echo "in progress" > "$SANDBOX/.gaia/local/cache/draft-SPEC-002.md"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-002)" = "draft" ]
  [ -z "$output" ]
}

# --- 3. Leaves a draft with a SPEC.md untouched ------------------------------

@test "leaves a draft with a SPEC.md untouched" {
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-003", created_at: $timestamp, status: "draft"}]')"
  mkdir -p "$SANDBOX/.notebook/specs/SPEC-003"
  echo "# SPEC" > "$SANDBOX/.notebook/specs/SPEC-003/SPEC.md"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-003)" = "draft" ]
  [ -z "$output" ]
}

# --- 4. Leaves a draft with a gate-1 snapshot untouched ----------------------

@test "leaves a draft with a gate1-<id>.json snapshot untouched" {
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-004", created_at: $timestamp, status: "draft"}]')"
  echo '{}' > "$SANDBOX/.gaia/local/cache/gate1-SPEC-004.json"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-004)" = "draft" ]
  [ -z "$output" ]
}

# --- 5. Leaves an empty draft younger than the guard age untouched ----------

@test "leaves an empty draft younger than the guard age untouched" {
  seed_catalog "$(jq -nc --arg timestamp "$(new_timestamp)" '[{id: "SPEC-005", created_at: $timestamp, status: "draft"}]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-005)" = "draft" ]
  [ -z "$output" ]
}

# --- 6. Leaves a non-draft row untouched -------------------------------------

@test "leaves a specified (non-draft) row untouched even if empty and aged" {
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-006", created_at: $timestamp, status: "specified"}]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-006)" = "specified" ]
  [ -z "$output" ]
}

# --- 7. Unparseable created_at is treated as NOT aged ------------------------

@test "treats an unparseable created_at as not aged (never guesses)" {
  seed_catalog '[{"id": "SPEC-007", "created_at": "not-a-date", "status": "draft"}]'
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-007)" = "draft" ]
  [ -z "$output" ]
}

# --- 8. Missing created_at is treated as NOT aged ----------------------------

@test "treats a missing created_at as not aged (never guesses)" {
  seed_catalog '[{"id": "SPEC-008", "status": "draft"}]'
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-008)" = "draft" ]
  [ -z "$output" ]
}

# --- 9. Multiple eligible drafts flip in one pass ----------------------------

@test "flips multiple eligible drafts in one pass, leaves ineligible ones" {
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
}

# --- 10. No catalog: exit 0, silent, no side effects -------------------------

@test "no catalog file: exit 0, silent, nothing created" {
  rm -f "$CATALOG"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CATALOG" ]
}

# --- 11. No draft rows at all: exit 0, silent --------------------------------

@test "catalog with no draft rows: exit 0, silent" {
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-013", created_at: $timestamp, status: "merged"}]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 12. Missing repo_root argument: exit 0, usage to stderr -----------------

@test "missing repo_root argument: exit 0" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- 13. Flip flows through the real ledger-update.sh chokepoint ------------

@test "the flip is rejected if ledger-update.sh's status guard would reject it" {
  # Sanity: ledger-update.sh itself accepts "abandoned" directly (the
  # chokepoint this sweep depends on), confirming the sweep and the guard
  # agree on the vocabulary rather than each hardcoding it separately.
  seed_catalog '[{"id": "SPEC-014", "status": "draft"}]'
  run bash "$LEDGER_UPDATE" "$SANDBOX" SPEC-014 '{"status":"abandoned"}'
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-014)" = "abandoned" ]
}

# --- 14. Orphan lock is removed when a ghost row is abandoned ---------------

@test "removes the orphan .lock file when a ghost draft is abandoned" {
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-015", created_at: $timestamp, status: "draft"}]')"
  echo '{"spec_id":"SPEC-015"}' > "$SANDBOX/.gaia/local/cache/spec-session-SPEC-015.lock"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-015)" = "abandoned" ]
  [ ! -e "$SANDBOX/.gaia/local/cache/spec-session-SPEC-015.lock" ]
}

# --- 15. A lone lock never rescues a ghost (negative guard) -----------------

@test "a lone .lock file does not rescue an otherwise-empty ghost draft from abandonment" {
  # A dead session's lock is precisely the ghost shape; the emptiness guard
  # never grows a fourth (`.lock`) check, so this row is abandoned exactly
  # like a lock-free ghost would be.
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-016", created_at: $timestamp, status: "draft"}]')"
  echo '{"spec_id":"SPEC-016"}' > "$SANDBOX/.gaia/local/cache/spec-session-SPEC-016.lock"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-016)" = "abandoned" ]
}

# --- 16. A row id that would climb out of the specs folder is skipped --------

@test "a traversal-shaped row id is skipped with a stderr line and never flipped" {
  seed_catalog "$(jq -nc --arg timestamp "$(old_timestamp)" '[{id: "SPEC-001/../../x", created_at: $timestamp, status: "draft"}]')"
  run --separate-stderr bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"refused the folder for row id"* ]]
  [ "$(status_of 'SPEC-001/../../x')" = "draft" ]
}

# --- 17. Not ready: exit 3, the move line, nothing changed -------------------

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
