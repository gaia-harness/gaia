#!/usr/bin/env bats
#
# Suite for the generalized notebook reconcile (.gaia/scripts/notebook/reconcile.sh):
# it compares catalog rows with folders for specs, plans and research, reports
# each mismatch by kind and path, registers a row-less research folder as
# untagged and changes nothing else.
#
# Every fixture is a throwaway git repository from helpers/tmp-notebook-repo.sh.
# A "byte manifest" is the sha256 of every file under the fixture's notebook
# (the catalog excepted) plus the sorted list of every path, so an added,
# removed or edited file or folder shows as a difference.
#
# Run under bash 5: bash .gaia/scripts/bats5.sh <this file> < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  unset GAIA_NOTEBOOK_TREE GAIA_NOTEBOOK_MEMORY_DIR GAIA_NOTEBOOK_CATALOG_LOCK_HELD \
    GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd -P)"
  REAL_ROOT="$(cd "$THIS_DIRECTORY/../../.." && pwd -P)"
  HELPER="$REAL_ROOT/.gaia/tests/lib/helpers/tmp-notebook-repo.sh"
  MOVE_COMMAND="bash .gaia/scripts/notebook/move.sh run"
  SANDBOX=""
  LINKED=""
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then rm -rf "$SANDBOX"; fi
  if [ -n "${LINKED:-}" ]; then rm -rf "$LINKED"; fi
}

# make_fixture <helper args>: sets SANDBOX (and LINKED when a worktree flag is given).
make_fixture() {
  local created
  created="$("$HELPER" "$@")"
  SANDBOX="$(printf '%s\n' "$created" | sed -n 1p)"
  LINKED="$(printf '%s\n' "$created" | sed -n 2p)"
  CATALOG="$SANDBOX/.notebook/catalog.json"
}

# digest_of <file>: sha256 of one file on both macOS and Linux.
digest_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# manifest_of <notebook dir>: every path, plus the digest of every file but the catalog.
manifest_of() {
  local notebook="$1" path
  (
    cd "$notebook" || exit 1
    find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r path; do
      if [ -f "$path" ] && [ "$path" != "./catalog.json" ]; then
        printf '%s %s\n' "$(digest_of "$path")" "$path"
      else
        printf -- '- %s\n' "$path"
      fi
    done
  )
}

# catalog_without <id>: the catalog with the one row removed, key-sorted.
catalog_without() {
  jq -S --arg id "$1" '.items |= map(select(.id != $id))' "$CATALOG"
}

# reconcile [args]: the fixture's own copy, run from inside the fixture so the
# notebook it resolves is the fixture's.
reconcile() {
  (cd "$SANDBOX" && bash .gaia/scripts/notebook/reconcile.sh "$@")
}

mixed_fixture() {
  make_fixture --seed-spec SPEC-001 ready --seed-spec-folder SPEC-002 draft \
    --seed-research-folder-only orphan-topic --seed-research-loose stray.md
  # A spec folder with no row, and a plan nested in a spec that has a row.
  mkdir -p "$SANDBOX/.notebook/specs/SPEC-003" "$SANDBOX/.notebook/specs/SPEC-002/plan"
  printf 'nested plan\n' > "$SANDBOX/.notebook/specs/SPEC-002/plan/PROGRESS.md"
}

@test "names each mismatch by kind and path, registers the research folder, changes nothing else" {
  mixed_fixture
  local before_manifest after_manifest before_catalog
  before_manifest="$(manifest_of "$SANDBOX/.notebook")"
  before_catalog="$(catalog_without orphan-topic)"

  run -0 reconcile
  expected="reconcile: research research/orphan-topic: registered untagged
reconcile: research research/stray.md: loose file
reconcile: spec specs/SPEC-001: row without folder
reconcile: spec specs/SPEC-003: folder without catalog row"
  [ "$output" = "$expected" ]
  grep -qF "plan" <<<"$output" && return 1

  after_manifest="$(manifest_of "$SANDBOX/.notebook")"
  [ "$after_manifest" = "$before_manifest" ]
  [ "$(catalog_without orphan-topic)" = "$before_catalog" ]
  [ "$(jq -r '[.items[] | select(.id == "orphan-topic")] | length' "$CATALOG")" = "1" ]
  [ "$(jq -r '.items[] | select(.id == "orphan-topic") | .kind + " " + .status + " " + .path' "$CATALOG")" = "research untagged research/orphan-topic" ]
  [ "$(jq -r '.items | length' "$CATALOG")" = "3" ]
}

@test "a second run prints the same lines except registered untagged and registers nothing" {
  mixed_fixture
  run -0 reconcile
  local first_output="$output" catalog_digest manifest
  catalog_digest="$(digest_of "$CATALOG")"
  manifest="$(manifest_of "$SANDBOX/.notebook")"

  run -0 reconcile
  [ "$output" = "$(printf '%s\n' "$first_output" | grep -vF ': registered untagged')" ]
  grep -qF 'registered untagged' <<<"$output" && return 1
  [ "$(digest_of "$CATALOG")" = "$catalog_digest" ]
  [ "$(manifest_of "$SANDBOX/.notebook")" = "$manifest" ]
}

@test "rows carrying a reap record are silent, with or without a folder" {
  make_fixture \
    --seed-row '{"kind":"spec","id":"SPEC-010","path":"specs/SPEC-010","status":"merged","reap":{"at":null,"by":"pre-catalog"}}' \
    --seed-row '{"kind":"spec","id":"SPEC-011","path":"specs/SPEC-011","status":"merged","reap":{"at":"2026-01-01T00:00:00Z","by":"spec-archive-merged"}}' \
    --seed-row '{"kind":"plan","id":"PLAN-010","path":"plans/PLAN-010","status":"merged","reap":{"at":null,"by":"pre-catalog"}}' \
    --seed-spec SPEC-012 ready
  run -0 reconcile
  [ "$output" = "reconcile: spec specs/SPEC-012: row without folder" ]
}

@test "plans are reconciled like specs and dotfiles and the catalog temp file are ignored" {
  make_fixture --seed-plan PLAN-001 ready --seed-plan-folder PLAN-002 ready
  mkdir -p "$SANDBOX/.notebook/plans/PLAN-003" "$SANDBOX/.notebook/research/.hidden"
  printf 'x\n' > "$SANDBOX/.notebook/.catalog.json.tmp.123"
  printf 'x\n' > "$SANDBOX/.notebook/research/.hidden-file"
  run -0 reconcile
  [ "$output" = "reconcile: plan plans/PLAN-001: row without folder
reconcile: plan plans/PLAN-003: folder without catalog row" ]
}

@test "a consistent notebook prints nothing" {
  make_fixture --seed-spec-folder SPEC-001 draft --seed-plan-folder PLAN-001 ready --seed-research topic active
  run -0 reconcile
  [ -z "$output" ]
}

@test "run from a linked worktree it reconciles main's notebook and registers into main's catalog" {
  make_fixture --seed-research-folder-only orphan-topic --worktree wt
  [ -n "$LINKED" ]
  [ -L "$LINKED/.notebook" ]
  run -0 bash -c 'cd "$1" && bash .gaia/scripts/notebook/reconcile.sh' _ "$LINKED"
  [ "$output" = "reconcile: research research/orphan-topic: registered untagged" ]
  [ "$(jq -r '[.items[] | select(.id == "orphan-topic" and .status == "untagged")] | length' "$CATALOG")" = "1" ]
}

@test "a not-ready notebook exits 3 with the move command and creates no row and no folder" {
  make_fixture --legacy --seed-research-folder-only orphan-topic
  local catalog_digest manifest
  catalog_digest="$(digest_of "$CATALOG")"
  manifest="$(manifest_of "$SANDBOX/.notebook")"

  run -3 --separate-stderr reconcile
  [ -z "$output" ]
  grep -qF "$MOVE_COMMAND" <<<"$stderr"
  [ "$(digest_of "$CATALOG")" = "$catalog_digest" ]
  [ "$(manifest_of "$SANDBOX/.notebook")" = "$manifest" ]
}

@test "a tree operand reconciles that fixture only, from the real checkout's cwd" {
  make_fixture --seed-research-folder-only orphan-topic
  local real_before=""
  if [ -e "$REAL_ROOT/.notebook" ]; then
    real_before="$(manifest_of "$REAL_ROOT/.notebook"; digest_of "$REAL_ROOT/.notebook/catalog.json" 2>/dev/null)"
  fi

  run -0 bash -c 'cd "$1" && bash "$2/.gaia/scripts/notebook/reconcile.sh" "$3"' _ "$REAL_ROOT" "$REAL_ROOT" "$SANDBOX"
  [ "$output" = "reconcile: research research/orphan-topic: registered untagged" ]
  [ "$(jq -r '[.items[] | select(.id == "orphan-topic")] | length' "$CATALOG")" = "1" ]

  if [ -e "$REAL_ROOT/.notebook" ]; then
    [ "$(manifest_of "$REAL_ROOT/.notebook"; digest_of "$REAL_ROOT/.notebook/catalog.json" 2>/dev/null)" = "$real_before" ]
  fi
}

@test "more than one operand is a usage error" {
  make_fixture --seed-spec SPEC-001 ready
  run -2 --separate-stderr reconcile one two
  grep -qF 'usage:' <<<"$stderr"
}
