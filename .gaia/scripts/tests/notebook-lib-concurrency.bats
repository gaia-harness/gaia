#!/usr/bin/env bats
#
# Locking suite for the notebook library (.gaia/scripts/notebook/): concurrent
# writers from the main checkout and a linked worktree released together
# through a barrier, with a lost-update twin proving the harness can see a
# lost write; a held catalog lock across many writes; the mint lock leaving
# catalog writes free; and a rename racing a research register.
#
# Writers start as background processes that spin on a barrier file, so they
# all reach the catalog at once when the test creates it.
#
# Run under bash 5: bash .gaia/scripts/bats5.sh <this file> < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  unset GAIA_NOTEBOOK_TREE GAIA_NOTEBOOK_MEMORY_DIR GAIA_NOTEBOOK_CATALOG_LOCK_HELD \
    GAIA_LEDGER_LOCK_FORCE_FALLBACK GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
  # Generous, so a slow CI host serializes the writers instead of timing out;
  # a deadlock still surfaces as a 75 well inside the bats run.
  export GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=60
  SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
  SCRATCH="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  # A cwd outside any repository: a call that ignored the tree selector would
  # fail to resolve rather than reach the checkout running this suite.
  cd "$SCRATCH" || return 1
  REPO="$(make_repo repo)"
  LIBRARY="$REPO/.gaia/scripts/notebook/notebook-lib.sh"
  CATALOG="$REPO/.notebook/catalog.json"
  BARRIER="$SCRATCH/barrier"
  WRITER_PIDS=()
}

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

make_worktree() {
  git -C "$REPO" worktree add -q -b side "$SCRATCH/worktree"
  printf '%s\n' "$(cd "$SCRATCH/worktree" && pwd -P)"
}

notebook() {
  GAIA_NOTEBOOK_TREE="$REPO" bash "$LIBRARY" "$@"
}

# launch_writer <tree> <label> <command...>: starts the command from <tree>
# once the barrier exists; release_and_wait creates it and counts failures.
launch_writer() {
  local tree="$1" label="$2"
  shift 2
  (
    cd "$tree" || exit 97
    while [ ! -e "$BARRIER" ]; do sleep 0.01; done
    "$@"
  ) >"$SCRATCH/writer-$label.log" 2>&1 &
  WRITER_PIDS+=("$!")
}

release_and_wait() {
  local pid failed=0
  : >"$BARRIER"
  for pid in "${WRITER_PIDS[@]}"; do
    wait "$pid" || failed=$((failed + 1))
  done
  WRITER_PIDS=()
  rm -f "$BARRIER"
  return "$failed"
}

# A read-modify-write with no lock, held open long enough that writers
# released together overlap. The suite's own stand-in for a lockless writer.
unlocked_register() {
  local slug="$1" current
  current="$(cat "$CATALOG")"
  sleep 0.05
  printf '%s' "$current" | jq --arg slug "$slug" \
    '.items += [{kind: "research", id: $slug, path: ("research/" + $slug), status: "active"}]' >"$CATALOG.tmp.$slug"
  mv -f "$CATALOG.tmp.$slug" "$CATALOG"
}

# Releases WRITER_COUNT registers, half from main and half from the worktree.
WRITER_COUNT=8

run_locked_round() {
  local worktree="$1" index tree
  for index in $(seq 1 "$WRITER_COUNT"); do
    tree="$REPO"
    [ $((index % 2)) -eq 0 ] && tree="$worktree"
    launch_writer "$tree" "w$index" bash "$tree/.gaia/scripts/notebook/notebook-lib.sh" register research "w$index-2026-10-01" active
  done
  release_and_wait
}

assert_every_writer_landed() {
  local index
  jq -e . "$CATALOG" >/dev/null
  [ "$(jq '.items | length' "$CATALOG")" -eq "$WRITER_COUNT" ]
  for index in $(seq 1 "$WRITER_COUNT"); do
    jq -e --arg id "w$index-2026-10-01" 'any(.items[]; .id == $id)' "$CATALOG" >/dev/null \
      || { echo "row w$index missing"; return 1; }
  done
}

@test "concurrent writers from main and a worktree all land under the mkdir lock" {
  local worktree
  worktree="$(make_worktree)"
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  run_locked_round "$worktree"
  assert_every_writer_landed
  [ -d "$REPO/.gaia/local/cache/shared/notebook-locks/catalog" ]
  [ ! -e "$worktree/.notebook" ]
}

@test "concurrent writers from main and a worktree all land under flock" {
  command -v flock >/dev/null 2>&1 || skip "flock is not installed on this host"
  local worktree
  worktree="$(make_worktree)"
  run_locked_round "$worktree"
  assert_every_writer_landed
}

@test "the same barrier harness with an unlocked writer loses an update (red twin)" {
  local round index lost=0
  mkdir -p "$REPO/.notebook"
  for round in 1 2 3 4 5; do
    printf '{"version":1,"items":[]}\n' >"$CATALOG"
    for index in $(seq 1 "$WRITER_COUNT"); do
      launch_writer "$REPO" "u$round-$index" unlocked_register "u$index-2026-10-01"
    done
    release_and_wait
    if [ "$(jq '.items | length' "$CATALOG")" -lt "$WRITER_COUNT" ]; then
      lost=1
      break
    fi
  done
  [ "$lost" -eq 1 ]
}

@test "a held catalog lock spans many writes without deadlock and makes an outside writer wait" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  # A library write that re-acquired the held lock would wait on itself and
  # time out here with 75 instead of hanging.
  GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=5 GAIA_NOTEBOOK_TREE="$REPO" bash -c '
    library="$1" scratch="$2"
    source "$library"
    block() {
      gaia_notebook_register research held-a-2026-10-01 active || return 11
      gaia_notebook_update research held-a-2026-10-01 "{\"status\":\"pending\"}" || return 12
      gaia_notebook_upsert research held-b-2026-10-01 "{\"status\":\"active\"}" || return 13
      bash "$library" register research held-c-2026-10-01 active || return 14
      : >"$scratch/inside-done"
      sleep 2
      : >"$scratch/releasing"
    }
    gaia_notebook_with_catalog_lock block' _ "$LIBRARY" "$SCRATCH" >"$SCRATCH/holder.log" 2>&1 &
  local holder="$!" waited=0
  while [ ! -e "$SCRATCH/inside-done" ] && [ "$waited" -lt 300 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -e "$SCRATCH/inside-done" ] || { cat "$SCRATCH/holder.log"; return 1; }
  run notebook register research outside-2026-10-01 active
  [ "$status" -eq 0 ]
  [ -e "$SCRATCH/releasing" ]
  wait "$holder"
  [ "$(jq -r '[.items[].id] | sort | join(",")' "$CATALOG")" = "held-a-2026-10-01,held-b-2026-10-01,held-c-2026-10-01,outside-2026-10-01" ]
  [ "$(jq -r '.items[] | select(.id == "held-a-2026-10-01") | .status' "$CATALOG")" = pending ]
}

@test "a held mint lock leaves catalog writes free and blocks a second mint" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  GAIA_NOTEBOOK_TREE="$REPO" bash -c '
    source "$1"
    hold() { : >"$1/minting"; sleep 4; : >"$1/mint-done"; }
    gaia_notebook_with_mint_lock spec hold "$2"' _ "$LIBRARY" "$SCRATCH" >"$SCRATCH/minter.log" 2>&1 &
  local minter="$!" waited=0
  while [ ! -e "$SCRATCH/minting" ] && [ "$waited" -lt 300 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -e "$SCRATCH/minting" ]
  run notebook register research during-mint-2026-10-01 active
  [ "$status" -eq 0 ]
  [ ! -e "$SCRATCH/mint-done" ]
  run env GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 GAIA_NOTEBOOK_TREE="$REPO" bash -c 'source "$1"; gaia_notebook_with_mint_lock spec true' _ "$LIBRARY"
  [ "$status" -eq 75 ]
  wait "$minter"
  [ -e "$SCRATCH/mint-done" ]
}

@test "a rename racing a research register loses neither write" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  local round
  for round in 1 2 3 4 5; do
    run notebook register spec "SPEC-10$round" draft --extra '{"source":"local"}'
    [ "$status" -eq 0 ]
  done
  for round in 1 2 3 4 5; do
    launch_writer "$REPO" "rename$round" bash -c 'source "$1"; gaia_notebook_rename spec "$2" "$3"' _ "$LIBRARY" "SPEC-10$round" "SPEC-20$round"
    launch_writer "$REPO" "register$round" bash "$LIBRARY" register research "r$round-2026-10-01" active
  done
  release_and_wait
  for round in 1 2 3 4 5; do
    jq -e --arg id "SPEC-20$round" 'any(.items[]; .id == $id and .renamed_from != null and .source == "local")' "$CATALOG" >/dev/null \
      || { echo "rename $round lost"; return 1; }
    jq -e --arg id "r$round-2026-10-01" 'any(.items[]; .id == $id)' "$CATALOG" >/dev/null \
      || { echo "register $round lost"; return 1; }
  done
  [ "$(jq '.items | length' "$CATALOG")" -eq 10 ]
}
