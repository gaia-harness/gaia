#!/usr/bin/env bats
#
# Path suite for the notebook library (.gaia/scripts/notebook/): id
# validation and folder containment, main anchoring from a linked worktree,
# the tree selector, folder and loose-file listing, path classification, move
# state, the auto-memory location and the legacy prefixes. Catalog semantics
# live in notebook-lib.bats and locking in notebook-lib-concurrency.bats.
#
# Every fixture is a throwaway git repository holding copies of the library
# and the two files it sources, at their real relative paths. Every library
# call names its tree through GAIA_NOTEBOOK_TREE or runs from inside a
# fixture, so no call can resolve the real checkout.
#
# Run under bash 5: bash .gaia/scripts/bats5.sh <this file> < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  unset GAIA_NOTEBOOK_TREE GAIA_NOTEBOOK_MEMORY_DIR GAIA_NOTEBOOK_CATALOG_LOCK_HELD \
    GAIA_LEDGER_LOCK_FORCE_FALLBACK GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
  SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
  SCRATCH="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  # A cwd outside any repository: a call that ignored the tree selector would
  # fail to resolve rather than reach the checkout running this suite.
  cd "$SCRATCH" || return 1
  REPO="$(make_repo repo)"
  LIBRARY="$REPO/.gaia/scripts/notebook/notebook-lib.sh"
  CATALOG="$REPO/.notebook/catalog.json"
  # shellcheck source=/dev/null
  source "$REPO/.gaia/scripts/notebook/legacy-roots.sh"
}

# make_repo <name>: prints the physical path of a new fixture repository with
# the library committed, so a linked worktree carries it too.
make_repo() {
  local repository="$SCRATCH/$1" relative
  mkdir -p "$repository"
  git -C "$repository" init -q --initial-branch=main
  git -C "$repository" config user.email gaia-test@example.com
  git -C "$repository" config user.name "GAIA Test"
  git -C "$repository" config commit.gpgsign false
  : >"$SCRATCH/empty-excludes"
  git -C "$repository" config core.excludesFile "$SCRATCH/empty-excludes"
  printf '.notebook\n' >"$repository/.gitignore"
  mkdir -p "$repository/.gaia/scripts/spec" "$repository/.gaia/scripts/notebook"
  for relative in .gaia/scripts/main-root-lib.sh .gaia/scripts/spec/with-ledger-lock.sh \
    .gaia/scripts/notebook/notebook-lib.sh .gaia/scripts/notebook/notebook-lib-catalog.sh \
    .gaia/scripts/notebook/notebook-lib-paths.sh .gaia/scripts/notebook/legacy-roots.sh; do
    cp "$SOURCE_ROOT/$relative" "$repository/$relative"
  done
  git -C "$repository" add -A
  git -C "$repository" commit -q -m init
  printf '%s\n' "$(cd "$repository" && pwd -P)"
}

notebook() {
  GAIA_NOTEBOOK_TREE="$REPO" bash "$LIBRARY" "$@"
}

notebook_sourced() {
  GAIA_NOTEBOOK_TREE="$REPO" bash -c 'source "$1"; eval "$2"' _ "$LIBRARY" "$1"
}

in_directory() {
  local directory="$1"
  shift
  (cd "$directory" && "$@")
}

file_digest() {
  if [ ! -e "$1" ]; then
    printf 'absent\n'
    return 0
  fi
  { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1"; } | cut -d' ' -f1
}

catalog_field() {
  jq -r "$1" "$CATALOG"
}

plant_legacy_ledger() {
  local legacy_directory
  legacy_directory="$(gaia_notebook_legacy_root "$1" "$REPO")"
  mkdir -p "$legacy_directory"
  printf '{}\n' >"$legacy_directory/ledger.json"
}

@test "path refuses invalid ids with 2 and prints a valid research path" {
  local invalid
  for invalid in 'spec ../x' 'spec SPEC-1' 'research ..' 'research a/b' 'plan PLAN-12x'; do
    # shellcheck disable=SC2086
    run notebook path $invalid
    [ "$status" -eq 2 ] || { echo "path $invalid exited $status"; return 1; }
  done
  run notebook path research 2026-10-01-a.b
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO/.notebook/research/2026-10-01-a.b" ]
  run notebook path plan
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO/.notebook/plans" ]
}

@test "item_directory refuses a symlinked item folder and a symlinked kind folder" {
  mkdir -p "$REPO/.notebook/specs" "$SCRATCH/elsewhere"
  run notebook_sourced 'gaia_notebook_item_directory spec SPEC-001'
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO/.notebook/specs/SPEC-001" ]
  ln -s "$SCRATCH/elsewhere" "$REPO/.notebook/specs/SPEC-001"
  run notebook_sourced 'gaia_notebook_item_directory spec SPEC-001'
  [ "$status" -eq 2 ]
  ln -s "$SCRATCH/elsewhere" "$REPO/.notebook/plans"
  run notebook_sourced 'gaia_notebook_item_directory plan PLAN-001'
  [ "$status" -eq 2 ]
}

@test "from a linked worktree, root and register resolve the main checkout" {
  local worktree="$SCRATCH/worktree"
  git -C "$REPO" worktree add -q -b side "$worktree"
  worktree="$(cd "$worktree" && pwd -P)"
  run in_directory "$worktree" bash "$worktree/.gaia/scripts/notebook/notebook-lib.sh" root
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO/.notebook" ]
  run in_directory "$worktree" bash "$worktree/.gaia/scripts/notebook/notebook-lib.sh" register research 2026-10-01-topic active
  [ "$status" -eq 0 ]
  [ "$(catalog_field '.items[0].id')" = 2026-10-01-topic ]
  [ ! -e "$worktree/.notebook" ]
}

@test "GAIA_NOTEBOOK_TREE, not the cwd, chooses the tree" {
  local other worktree before_other
  other="$(make_repo other)"
  worktree="$SCRATCH/repo-worktree"
  git -C "$REPO" worktree add -q -b side "$worktree"
  before_other="$(file_digest "$other/.notebook/catalog.json")"

  run in_directory "$other" env GAIA_NOTEBOOK_TREE="$REPO" bash "$LIBRARY" register research 2026-10-01-t active
  [ "$status" -eq 0 ]
  run in_directory "$other" env GAIA_NOTEBOOK_TREE="$REPO" bash -c 'source "$1"; gaia_notebook_register research 2026-10-01-sourced active' _ "$LIBRARY"
  [ "$status" -eq 0 ]
  run in_directory "$SCRATCH" env GAIA_NOTEBOOK_TREE="$worktree" bash "$LIBRARY" register research 2026-10-01-via-worktree active
  [ "$status" -eq 0 ]
  [ "$(catalog_field '[.items[].id] | sort | join(",")')" = "2026-10-01-sourced,2026-10-01-t,2026-10-01-via-worktree" ]
  [ "$(file_digest "$other/.notebook/catalog.json")" = "$before_other" ]
  [ ! -e "$other/.notebook" ]
  [ ! -e "$worktree/.notebook" ]

  run in_directory "$other" bash "$LIBRARY" register research 2026-10-01-t active
  [ "$status" -eq 0 ]
  [ "$(jq -r '.items[0].id' "$other/.notebook/catalog.json")" = 2026-10-01-t ]
}

@test "folders lists item folders only and loose_files lists regular files only" {
  mkdir -p "$REPO/.notebook/specs/SPEC-001/plan" "$REPO/.notebook/specs/SPEC-002" "$REPO/.notebook/specs/.hidden" \
    "$REPO/.notebook/research/2026-10-01-topic" "$SCRATCH/elsewhere"
  : >"$REPO/.notebook/specs/notes.md"
  : >"$REPO/.notebook/specs/catalog.json"
  ln -s "$SCRATCH/elsewhere" "$REPO/.notebook/specs/SPEC-009"
  : >"$REPO/.notebook/research/loose.md"
  : >"$REPO/.notebook/research/.DS_Store"
  ln -s "$REPO/.notebook/research/loose.md" "$REPO/.notebook/research/linked.md"
  run notebook folders spec
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'SPEC-001\nSPEC-002')" ]
  run notebook folders plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run notebook_sourced 'gaia_notebook_loose_files research'
  [ "$status" -eq 0 ]
  [ "$output" = loose.md ]
  run notebook_sourced 'gaia_notebook_loose_files spec'
  [ "$status" -eq 2 ]
}

@test "classify names the four shapes from absolute and repo-relative paths, and refuses outside paths" {
  local worktree="$SCRATCH/worktree" relative expected
  mkdir -p "$REPO/.notebook/specs/SPEC-001/plan-2"
  local cases=(
    '.notebook/specs/SPEC-001|spec SPEC-001'
    '.notebook/specs/SPEC-001/plan-2/README.md|spec-plan SPEC-001 plan-2'
    '.notebook/plans/PLAN-003|plan PLAN-003'
    '.notebook/research/2026-10-01-t/notes.md|research 2026-10-01-t'
  )
  local case_line
  for case_line in "${cases[@]}"; do
    relative="${case_line%%|*}"
    expected="${case_line#*|}"
    run notebook classify "$relative"
    [ "$status" -eq 0 ] && [ "$output" = "$expected" ] || { echo "relative $relative -> $status $output"; return 1; }
    run notebook classify "./$relative"
    [ "$output" = "$expected" ]
    run notebook classify "$REPO/$relative"
    [ "$status" -eq 0 ] && [ "$output" = "$expected" ] || { echo "absolute $relative -> $status $output"; return 1; }
  done
  git -C "$REPO" worktree add -q -b side "$worktree"
  ln -s "$REPO/.notebook" "$worktree/.notebook"
  run notebook classify "$worktree/.notebook/specs/SPEC-001/plan-2/README.md"
  [ "$status" -eq 0 ]
  [ "$output" = "spec-plan SPEC-001 plan-2" ]
  for relative in "$REPO/src/x" .gaia/local/x .notebook/catalog.json .notebook/specs/SPEC-1 "$SCRATCH/x/.notebook/specs/SPEC-001"; do
    run notebook classify "$relative"
    [ "$status" -eq 1 ] || { echo "$relative -> $status $output"; return 1; }
  done
}

@test "move-state reports none, pending per old root, and done once the marker lands; never 3" {
  run notebook move-state
  [ "$status" -eq 0 ]
  [ "$output" = none ]
  local kind legacy_directory
  for kind in specs plans research; do
    legacy_directory="$(gaia_notebook_legacy_root "$kind" "$REPO")"
    mkdir -p "$legacy_directory"
    run notebook move-state
    [ "$status" -eq 0 ] && [ "$output" = pending ] || { echo "$kind -> $status $output"; return 1; }
    rmdir "$legacy_directory"
    run notebook move-state
    [ "$output" = none ]
  done
  plant_legacy_ledger specs
  run notebook move-state
  [ "$status" -eq 0 ]
  [ "$output" = pending ]
  mkdir -p "$REPO/.notebook"
  printf '{"version":1,"move_complete":{"at":"2026-10-01T00:00:00Z"},"items":[]}\n' >"$CATALOG"
  run notebook move-state
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "memory_directory matches the cleanse formula and honors the override" {
  local expected
  expected="$SCRATCH/home/.claude/projects/$(echo "$REPO" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
  run env HOME="$SCRATCH/home" GAIA_NOTEBOOK_TREE="$REPO" bash -c 'source "$1"; gaia_notebook_memory_directory' _ "$LIBRARY"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  run env GAIA_NOTEBOOK_MEMORY_DIR="$SCRATCH/override" GAIA_NOTEBOOK_TREE="$REPO" bash -c 'source "$1"; gaia_notebook_memory_directory' _ "$LIBRARY"
  [ "$status" -eq 0 ]
  [ "$output" = "$SCRATCH/override" ]
}

@test "legacy_prefix prints the old repo-relative prefix per kind and refuses an unknown kind" {
  run gaia_notebook_legacy_prefix research
  [ "$status" -eq 0 ]
  [ "$output" = .gaia/local/research/ ]
  run gaia_notebook_legacy_prefix specs
  [ "$output" = .gaia/local/specs/ ]
  run gaia_notebook_legacy_prefix plans
  [ "$output" = .gaia/local/plans/ ]
  run gaia_notebook_legacy_prefix spec
  [ "$status" -eq 2 ]
}
