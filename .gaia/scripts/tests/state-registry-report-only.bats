#!/usr/bin/env bats
#
# The report_only block of .gaia/state-registry.json and the residue sweep's
# section for the old notebook roots (.gaia/local/specs, plans, research).
# Those roots hold what the one-time move keeps, and before the move they hold
# everything, so the sweep lists them once, tells a human what to do, and never
# deletes anything under them.
#
# Each case builds a scratch main checkout holding this branch's registry, the
# lib, and the notebook library it asks for the move state. Every refusal has
# a red twin: a fixture registry that removes the block (or re-adds a residue
# row beneath an old root) and shows the sweep would otherwise list or delete.
#
# Run under bash 5: bash .gaia/scripts/bats5.sh <this file> < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
  REGISTRY="$REPO_ROOT/.gaia/state-registry.json"
}

# make_main: a scratch main checkout with the shipped registry, the lib and the
# notebook library copies at their real relative paths. Sets MAIN, LOCAL_ROOT.
make_main() {
  MAIN="$(mktemp -d "$BATS_TEST_TMPDIR/main.XXXXXX")"
  MAIN="$(cd "$MAIN" && pwd -P)"
  mkdir -p "$MAIN/.gaia/scripts/notebook" "$MAIN/.gaia/scripts/spec" "$MAIN/.gaia/local"
  cp "$SCRIPT_DIRECTORY/state-registry-lib.sh" "$SCRIPT_DIRECTORY/main-root-lib.sh" "$MAIN/.gaia/scripts/"
  cp "$SCRIPT_DIRECTORY/spec/with-ledger-lock.sh" "$MAIN/.gaia/scripts/spec/"
  cp "$SCRIPT_DIRECTORY"/notebook/*.sh "$MAIN/.gaia/scripts/notebook/"
  cp "$REGISTRY" "$MAIN/.gaia/state-registry.json"
  git -C "$MAIN" init -q
  LOCAL_ROOT="$MAIN/.gaia/local"
}

# mark_moved: a catalog carrying the one-time move marker.
mark_moved() {
  mkdir -p "$MAIN/.notebook"
  printf '{"version":1,"items":[],"move_complete":{"at":"2026-10-01T00:00:00Z"}}\n' >"$MAIN/.notebook/catalog.json"
}

# put <relative path>: a file under .gaia/local, parents included.
put() {
  mkdir -p "$(dirname "$LOCAL_ROOT/$1")"
  printf 'content of %s\n' "$1" >"$LOCAL_ROOT/$1"
}

# registry_edit <jq filter>: rewrite the scratch registry through a jq filter.
registry_edit() {
  jq "$1" "$MAIN/.gaia/state-registry.json" >"$MAIN/registry.edited"
  mv "$MAIN/registry.edited" "$MAIN/.gaia/state-registry.json"
}

# snapshot <dir>: every file under it with its sha256, sorted.
snapshot() {
  if command -v sha256sum >/dev/null 2>&1; then
    find "$1" -type f -exec sha256sum {} + | LC_ALL=C sort
  else
    find "$1" -type f -exec shasum -a 256 {} + | LC_ALL=C sort
  fi
}

# sweep [args...]: run residue-sweep from inside the scratch main checkout.
sweep() {
  # shellcheck disable=SC2016
  run --separate-stderr "$BASH" -c 'cd "$1" && shift && "$BASH" .gaia/scripts/state-registry-lib.sh residue-sweep "$@"' _ "$MAIN" "$@"
}

# section <heading word>: the indented lines under the heading starting with it.
section() {
  printf '%s\n' "$output" | awk -v heading="$1" '
    /^[^ ]/ { in_section = (index($0, heading) == 1); next }
    in_section && /^  / { sub(/^  /, ""); print }
  '
}

# ========== the registry ==========

@test "registry: the three old roots are report-only rows and no residue row sits under them" {
  [ "$(jq -r '[.report_only[].path] | sort | join(",")' "$REGISTRY")" = "plans/,research/,specs/" ]
  [ "$(jq -r '[.report_only[] | select(.root == "local" and .match == "prefix")] | length' "$REGISTRY")" -eq 3 ]
  [ -z "$(jq '.residue[] | select(.path | test("^(specs|plans|research)/"))' "$REGISTRY")" ]
}

@test "recognizes and classify: a path under an old root is recognized as report-only, never unknown" {
  make_main
  local relative
  for relative in specs/SPEC-001/SPEC.md specs/archived/old/x.md plans/cache-consolidation/README.md plans/code-review-audit-ci/z.md research/topic-2026-10-01; do
    run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh recognizes "$2" f' _ "$MAIN" "$relative"
    [ "$status" -eq 0 ] || { echo "not recognized: $relative"; return 1; }
    run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh classify "$2"' _ "$MAIN" "$relative"
    [ "$output" = "report-only" ] || { echo "not report-only: $relative got $output"; return 1; }
  done
}

@test "red twin: without the report_only block the old roots are unknown" {
  make_main
  registry_edit 'del(.report_only)'
  run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh recognizes specs/SPEC-001 d' _ "$MAIN"
  [ "$status" -eq 1 ]
  run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh classify specs/SPEC-001' _ "$MAIN"
  [ "$output" = "unknown" ]
}

# ========== the sweep section ==========

@test "before the move: specs/ appears only in the report-only section with the move command, and --apply changes nothing" {
  make_main
  mkdir -p "$MAIN/.notebook/specs"
  put specs/ledger.json
  put specs/SPEC-001/SPEC.md
  sweep
  [ "$status" -eq 0 ]
  section Old | grep -qx 'specs/'
  [ "$(section Old | grep -c '^specs/')" -eq 1 ]
  section Old | grep -q 'Not yet moved.*bash .gaia/scripts/notebook/move.sh run'
  [ "$(section Residue | grep -c 'specs')" -eq 0 ]
  [ "$(section Unknown | grep -c 'specs')" -eq 0 ]
  local before after
  before="$(snapshot "$LOCAL_ROOT/specs")"
  [ -n "$before" ]
  sweep --apply
  [ "$status" -eq 0 ]
  after="$(snapshot "$LOCAL_ROOT/specs")"
  [ "$before" = "$after" ]
  [ "$(find "$LOCAL_ROOT/specs" -type f | wc -l | tr -d ' ')" -eq 2 ]
}

@test "red twin: without the block the same fixture lists specs/ under Unknown, and a successor-gated row would delete it" {
  make_main
  mark_moved
  put specs/SPEC-001/SPEC.md
  registry_edit 'del(.report_only)'
  sweep
  section Unknown | grep -qx 'specs'
  registry_edit '.residue += [{"id":"twin","path":"specs/","match":"prefix","why":"twin","writer":"none-residue","successor":"codify/"}] | .entries += [{"id":"twin-codify","path":"codify/","match":"prefix","kind":"dir","scope":"shared","keyed_by":"x","why":"x","writer":"code","retention":{"class":"keep"}}]'
  mkdir -p "$LOCAL_ROOT/codify"
  sweep
  section Residue | grep -q '^specs'
  sweep --apply
  [ ! -e "$LOCAL_ROOT/specs" ]
}

@test "red twin: with the block restored the successor-gated row cannot delete the root" {
  make_main
  mark_moved
  put specs/SPEC-001/SPEC.md
  registry_edit '.residue += [{"id":"twin","path":"specs/","match":"prefix","why":"twin","writer":"none-residue","successor":"codify/"}] | .entries += [{"id":"twin-codify","path":"codify/","match":"prefix","kind":"dir","scope":"shared","keyed_by":"x","why":"x","writer":"code","retention":{"class":"keep"}}]'
  mkdir -p "$LOCAL_ROOT/codify"
  sweep --apply
  [ "$status" -eq 0 ]
  [ -f "$LOCAL_ROOT/specs/SPEC-001/SPEC.md" ]
  [ "$(section Residue | grep -c 'specs')" -eq 0 ]
}

@test "after the move: both roots are listed as moved with leftovers to review, and --apply leaves them intact" {
  make_main
  mark_moved
  put specs/SPEC-002/SPEC.md
  put specs/ledger.pre-notebook.json
  put plans/cache-consolidation/README.md
  local before after
  before="$(snapshot "$LOCAL_ROOT")"
  sweep
  [ "$status" -eq 0 ]
  section Old | grep -qx 'specs/'
  section Old | grep -qx 'plans/'
  [ "$(section Old | grep -c 'Moved to .notebook/')" -eq 1 ]
  section Old | grep -q 'review it by hand'
  [ "$(section Old | grep -c 'Not yet moved')" -eq 0 ]
  sweep --apply
  [ "$status" -eq 0 ]
  after="$(snapshot "$LOCAL_ROOT")"
  [ "$before" = "$after" ]
}

@test "archived layouts are report-only: not residue, not unknown, byte-identical after --apply" {
  make_main
  mark_moved
  put specs/archived/old/x.md
  put plans/archived/y.md
  put plans/code-review-audit-ci/z.md
  local before after
  before="$(snapshot "$LOCAL_ROOT")"
  sweep
  [ "$status" -eq 0 ]
  [ "$(section Residue | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(section Unknown | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(section Old | grep -c '^specs/\|^plans/')" -eq 2 ]
  section Old | grep -q 'archived/'
  sweep --apply
  [ "$status" -eq 0 ]
  after="$(snapshot "$LOCAL_ROOT")"
  [ "$before" = "$after" ]
}

@test "red twin: a re-added successor-less archived residue row still deletes nothing under an old root" {
  make_main
  mark_moved
  put specs/archived/old/x.md
  put plans/archived/y.md
  registry_edit '.residue += [{"id":"twin-specs","path":"specs/archived/","match":"prefix","why":"twin","writer":"none-residue"},{"id":"twin-plans","path":"plans/archived/","match":"prefix","why":"twin","writer":"none-residue"}]'
  local before after
  before="$(snapshot "$LOCAL_ROOT")"
  sweep --apply
  [ "$status" -eq 0 ]
  [ "$(section Residue | wc -l | tr -d ' ')" -eq 0 ]
  after="$(snapshot "$LOCAL_ROOT")"
  [ "$before" = "$after" ]
  # The same row beneath a root the block does not name is deleted, so the
  # survivors above are the report-only refusal and not a sweep that deletes
  # nothing.
  registry_edit '.report_only |= map(select(.path != "plans/"))'
  sweep --apply
  [ ! -e "$LOCAL_ROOT/plans/archived" ]
  [ -f "$LOCAL_ROOT/specs/archived/old/x.md" ]
}

@test "research root is listed once however many children it holds" {
  make_main
  mark_moved
  put research/topic-a/STATE.md
  put research/topic-b/notes/deep.md
  sweep
  [ "$(section Old | grep -c '^research/')" -eq 1 ]
}

@test "no old root present: the section is absent" {
  make_main
  put audit/abc.carried
  sweep
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^Old notebook roots')" -eq 0 ]
}

@test "unreadable move state: the section says so, treats the roots as not yet moved, and --apply deletes nothing under them" {
  make_main
  mark_moved
  put specs/SPEC-002/SPEC.md
  put plans/archived/y.md
  rm "$MAIN/.gaia/scripts/notebook/notebook-lib.sh"
  local before after
  before="$(snapshot "$LOCAL_ROOT")"
  sweep
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^Old notebook roots.*could not read the move state'
  section Old | grep -q 'Not yet moved.*move.sh run'
  sweep --apply
  [ "$status" -eq 0 ]
  after="$(snapshot "$LOCAL_ROOT")"
  [ "$before" = "$after" ]
}

@test "residue outside the old roots is still swept beside a report-only root" {
  make_main
  mark_moved
  put audit/abc.carried
  put specs/SPEC-002/SPEC.md
  sweep --apply
  [ "$status" -eq 0 ]
  [ ! -e "$LOCAL_ROOT/audit/abc.carried" ]
  [ -f "$LOCAL_ROOT/specs/SPEC-002/SPEC.md" ]
}
