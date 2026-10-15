#!/usr/bin/env bats
# End-to-end behavior of the spec scripts on the notebook: a fresh repo's first
# spec lives under the notebook and never under the old machine-local specs
# folder; the two reapers delete only the notebook's folder (from main and from
# a linked worktree), record a reap on the row, and refuse an id or a symlink
# that would reach outside it; a notebook whose one-time move has not run is
# left untouched; the mint lock never stalls a plan or research write; and a
# fixture operand keeps every script away from the real checkout's notebook.
#
# Each test builds its own tmp repo via helpers/tmp-notebook-repo.sh and tears
# it down. Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  ALLOCATOR=".gaia/scripts/spec/spec-allocator.sh"
  ARCHIVE_MERGED=".gaia/scripts/spec/spec-archive-merged.sh"
  ARCHIVE_ABANDONED=".gaia/scripts/spec/spec-archive-abandoned.sh"
  LEDGER_UPDATE=".gaia/scripts/spec/ledger-update.sh"
  NOTEBOOK_LIBRARY=".gaia/scripts/notebook/notebook-lib.sh"
  MOVE_LINE="bash .gaia/scripts/notebook/move.sh run"
  REAL_ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  # shellcheck source=helpers/usage-gate.sh
  . "$HELPERS/usage-gate.sh"
  # The seeded merged_at and abandoned_at are fixed old stamps; collapsing the
  # window keeps every reap deterministic regardless of wall-clock time.
  export GAIA_SPEC_RETENTION_DAYS=0
  export GAIA_SPEC_FORCE_OFFLINE=1
  REPO=""
  WORKTREE=""
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO" "${REPO}.git" "${REPO}-wt"
  fi
}

# Every path under a directory plus a checksum per file, sorted, ".git" left out:
# two equal snapshots mean nothing was created, removed or rewritten.
_snapshot() {
  local root="$1"
  if [ ! -e "$root" ]; then
    echo "absent"
    return 0
  fi
  find "$root" -path "$root/.git" -prune -o -print | sort
  find "$root" -path "$root/.git" -prune -o -type f -exec shasum {} + | sort
}

_row_field() {
  jq -r --arg id "$2" --arg field "$3" \
    '[.items[] | select(.kind == "spec" and .id == $id)][0][$field] // "null"' "$1/.notebook/catalog.json"
}

_close_row() {
  seed_close_row "$REPO/.gaia/local/telemetry" "$1" "$2"
}

# --- Fresh adopter flow -------------------------------------------------------

@test "1: a fresh repo's first spec is minted, foldered and readied inside the notebook; the old specs folder never appears" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --no-catalog)"
  [ ! -e "$REPO/.notebook" ]
  [ ! -e "$REPO/.gaia/local/specs" ]

  run bash "$REPO/$ALLOCATOR" next "$REPO" "first subject"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-001" ]
  [ ! -e "$REPO/.gaia/local/specs" ]
  [ "$(jq -r '[.items[] | select(.kind == "spec")] | length' "$REPO/.notebook/catalog.json")" -eq 1 ]
  [ "$(_row_field "$REPO" SPEC-001 kind)" = "spec" ]
  [ "$(_row_field "$REPO" SPEC-001 status)" = "draft" ]

  folder="$(GAIA_NOTEBOOK_TREE="$REPO" bash "$REPO/$NOTEBOOK_LIBRARY" path spec SPEC-001)"
  [ "$folder" = "$REPO/.notebook/specs/SPEC-001" ]
  mkdir -p "$folder"
  printf -- '---\nspec_id: SPEC-001\nstatus: in-progress\n---\n\n# SPEC-001\n' > "$folder/SPEC.md"
  [ ! -e "$REPO/.gaia/local/specs" ]

  run bash "$REPO/$LEDGER_UPDATE" "$REPO" SPEC-001 '{"status":"ready"}'
  [ "$status" -eq 0 ]
  [ -f "$REPO/.notebook/specs/SPEC-001/SPEC.md" ]
  [ "$(_row_field "$REPO" SPEC-001 status)" = "ready" ]
  [ ! -e "$REPO/.gaia/local/specs" ]
}

# --- Reapers: main and linked worktree, decoys untouched ----------------------

# _plant_decoys <tree>: same-named folders outside the notebook that a reap
# must never reach.
_plant_decoys() {
  local tree="$1" id="$2"
  mkdir -p "$tree/.gaia/local/specs/$id" "$tree/.notebook-elsewhere/specs/$id"
  printf 'keep\n' > "$tree/.gaia/local/specs/$id/keep.txt"
  printf 'keep\n' > "$tree/.notebook-elsewhere/specs/$id/keep.txt"
}

_assert_decoys() {
  [ -f "$1/.gaia/local/specs/$2/keep.txt" ]
  [ -f "$1/.notebook-elsewhere/specs/$2/keep.txt" ]
}

@test "2a: spec-archive-merged run from main deletes the notebook folder, stamps a reap and leaves decoys" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001)"
  _close_row spec:SPEC-001 gaia-spec
  _plant_decoys "$REPO" SPEC-001

  run bash "$REPO/$ARCHIVE_MERGED" "$REPO"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.notebook/specs/SPEC-001" ]
  [ "$(_row_field "$REPO" SPEC-001 status)" = "merged" ]
  [ "$(jq -r '.items[0].reap.by' "$REPO/.notebook/catalog.json")" = "spec-archive-merged.sh" ]
  [ "$(jq -r '.items[0].reap.at | type' "$REPO/.notebook/catalog.json")" = "string" ]
  _assert_decoys "$REPO" SPEC-001
}

@test "2b: spec-archive-merged run from a linked worktree deletes main's notebook folder, stamps a reap and leaves decoys" {
  fixture="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001 --worktree wt)"
  REPO="$(printf '%s\n' "$fixture" | sed -n 1p)"
  WORKTREE="$(printf '%s\n' "$fixture" | sed -n 2p)"
  _close_row spec:SPEC-001 gaia-spec
  _plant_decoys "$WORKTREE" SPEC-001

  run bash "$WORKTREE/$ARCHIVE_MERGED" "$WORKTREE"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.notebook/specs/SPEC-001" ]
  [ "$(jq -r '.items[0].reap.by' "$REPO/.notebook/catalog.json")" = "spec-archive-merged.sh" ]
  _assert_decoys "$WORKTREE" SPEC-001
}

@test "2c: spec-archive-abandoned run from main deletes the notebook folder, stamps a reap and leaves decoys" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-002)"
  _plant_decoys "$REPO" SPEC-002

  run bash "$REPO/$ARCHIVE_ABANDONED" "$REPO"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.notebook/specs/SPEC-002" ]
  [ "$(_row_field "$REPO" SPEC-002 status)" = "abandoned" ]
  [ "$(jq -r '.items[0].reap.by' "$REPO/.notebook/catalog.json")" = "spec-archive-abandoned.sh" ]
  _assert_decoys "$REPO" SPEC-002
}

@test "2d: spec-archive-abandoned run from a linked worktree deletes main's notebook folder, stamps a reap and leaves decoys" {
  fixture="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-abandoned-folder SPEC-002 --worktree wt)"
  REPO="$(printf '%s\n' "$fixture" | sed -n 1p)"
  WORKTREE="$(printf '%s\n' "$fixture" | sed -n 2p)"
  _plant_decoys "$WORKTREE" SPEC-002

  run bash "$WORKTREE/$ARCHIVE_ABANDONED" "$WORKTREE"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.notebook/specs/SPEC-002" ]
  [ "$(jq -r '.items[0].reap.by' "$REPO/.notebook/catalog.json")" = "spec-archive-abandoned.sh" ]
  _assert_decoys "$WORKTREE" SPEC-002
}

# --- Path containment (red twins) ---------------------------------------------

# _traversal_row <id> <status> <stamp field>: a catalog row whose id climbs out
# of the specs folder.
_traversal_row() {
  jq -cn --arg id "$1" --arg status "$2" --arg stamp_field "$3" \
    '{kind: "spec", id: $id, path: ("specs/" + $id), status: $status,
      subject: "traversal", created_at: "2026-01-01T00:00:00Z",
      status_changed_at: "2026-01-01T00:00:00Z"} + {($stamp_field): "2026-01-01T00:00:00Z"}'
}

_assert_traversal_refused() {
  [ "$status" -eq 0 ]
  [ -n "$stderr" ]
  [ -f "$REPO/.notebook/x/keep.txt" ]
  [ -d "$REPO/.notebook/specs/SPEC-001" ]
  [ -f "$REPO/.notebook/catalog.json" ]
}

@test "3a: a merged row whose id climbs out of the specs folder is skipped with a stderr line and nothing outside is removed" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001 --seed-row "$(_traversal_row 'SPEC-001/../../x' merged merged_at)")"
  mkdir -p "$REPO/.notebook/x"
  printf 'keep\n' > "$REPO/.notebook/x/keep.txt"
  _close_row 'spec:SPEC-001/../../x' gaia-spec

  run --separate-stderr bash "$REPO/$ARCHIVE_MERGED" "$REPO"
  _assert_traversal_refused
}

@test "3b: an abandoned row whose id climbs out of the specs folder is skipped with a stderr line and nothing outside is removed" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-folder SPEC-001 draft --seed-row "$(_traversal_row 'SPEC-001/../../x' abandoned abandoned_at)")"
  mkdir -p "$REPO/.notebook/x"
  printf 'keep\n' > "$REPO/.notebook/x/keep.txt"

  run --separate-stderr bash "$REPO/$ARCHIVE_ABANDONED" "$REPO"
  _assert_traversal_refused
}

@test "3c: a merged row with the id .. is skipped and the notebook survives" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001 --seed-row "$(_traversal_row '..' merged merged_at)")"
  mkdir -p "$REPO/.notebook/x"
  printf 'keep\n' > "$REPO/.notebook/x/keep.txt"
  _close_row 'spec:..' gaia-spec

  run --separate-stderr bash "$REPO/$ARCHIVE_MERGED" "$REPO"
  _assert_traversal_refused
}

@test "3d: an abandoned row with the id .. is skipped and the notebook survives" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-folder SPEC-001 draft --seed-row "$(_traversal_row '..' abandoned abandoned_at)")"
  mkdir -p "$REPO/.notebook/x"
  printf 'keep\n' > "$REPO/.notebook/x/keep.txt"

  run --separate-stderr bash "$REPO/$ARCHIVE_ABANDONED" "$REPO"
  _assert_traversal_refused
}

@test "3e: a merged spec folder that is a symlink out of the notebook is refused and its target survives" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 merged)"
  outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside" "$REPO/.notebook/specs"
  printf -- '---\nspec_id: SPEC-001\nstatus: specified\nimmutable: true\n---\n' > "$outside/SPEC.md"
  printf -- '---\nwiki_promote_default: ask\nwiki_promote_targets: []\n---\n# SPEC-001\n\nBody.\n' > "$outside/SUMMARY.md"
  ln -s "$outside" "$REPO/.notebook/specs/SPEC-001"
  _close_row spec:SPEC-001 gaia-spec

  run --separate-stderr bash "$REPO/$ARCHIVE_MERGED" "$REPO"
  [ "$status" -eq 0 ]
  [ -n "$stderr" ]
  [ -f "$outside/SPEC.md" ]
  [ -f "$outside/SUMMARY.md" ]
  [ -L "$REPO/.notebook/specs/SPEC-001" ]
  [ "$(_row_field "$REPO" SPEC-001 reap)" = "null" ]
}

@test "3f: an abandoned spec folder that is a symlink out of the notebook is refused and its target survives" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 abandoned)"
  outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside" "$REPO/.notebook/specs"
  printf 'keep\n' > "$outside/AUDIT.md"
  ln -s "$outside" "$REPO/.notebook/specs/SPEC-001"

  run --separate-stderr bash "$REPO/$ARCHIVE_ABANDONED" "$REPO"
  [ "$status" -eq 0 ]
  [ -n "$stderr" ]
  [ -f "$outside/AUDIT.md" ]
  [ -L "$REPO/.notebook/specs/SPEC-001" ]
  [ "$(_row_field "$REPO" SPEC-001 reap)" = "null" ]
}

# --- Not ready: the one-time move has not run ---------------------------------

@test "4a: next in a not-ready repo refuses with the move line and changes nothing" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --legacy)"
  before="$(_snapshot "$REPO")"

  run --separate-stderr bash "$REPO/$ALLOCATOR" next "$REPO" "subject"
  [ "$status" -ne 0 ]
  grep -qF -- "$MOVE_LINE" <<<"$stderr"
  [ "$(_snapshot "$REPO")" = "$before" ]
}

@test "4b: spec-archive-merged in a not-ready repo refuses with the move line and deletes nothing" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --legacy --seed-spec-merged-folder SPEC-001)"
  _close_row spec:SPEC-001 gaia-spec
  before="$(_snapshot "$REPO")"

  run --separate-stderr bash "$REPO/$ARCHIVE_MERGED" "$REPO"
  [ "$status" -ne 0 ]
  grep -qF -- "$MOVE_LINE" <<<"$stderr"
  [ "$(_snapshot "$REPO")" = "$before" ]
}

@test "4c: spec-archive-abandoned in a not-ready repo refuses with the move line and deletes nothing" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --legacy --seed-spec-abandoned-folder SPEC-002)"
  before="$(_snapshot "$REPO")"

  run --separate-stderr bash "$REPO/$ARCHIVE_ABANDONED" "$REPO"
  [ "$status" -ne 0 ]
  grep -qF -- "$MOVE_LINE" <<<"$stderr"
  [ "$(_snapshot "$REPO")" = "$before" ]
}

# --- Mint lock isolation ------------------------------------------------------

@test "5: a plan row update and a research register finish while a spec allocation sits in its remote reservation" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --with-origin --seed-plan PLAN-001 ready)"
  origin="${REPO}.git"
  entered="$BATS_TEST_TMPDIR/hook-entered"
  mkdir -p "$origin/hooks"
  cat > "$origin/hooks/update" <<EOF
#!/usr/bin/env bash
case "\$1" in
  refs/tags/spec/*) : > '$entered'; sleep 6 ;;
esac
exit 0
EOF
  chmod +x "$origin/hooks/update"
  git -C "$origin" config core.hooksPath "$origin/hooks"

  GAIA_SPEC_FORCE_OFFLINE="" GAIA_SPEC_REMOTE_TIMEOUT_SECONDS=30 \
    bash "$REPO/$ALLOCATOR" next "$REPO" "slow reservation" > "$BATS_TEST_TMPDIR/next.out" 2> "$BATS_TEST_TMPDIR/next.err" &
  allocation_pid=$!

  waited=0
  while [ ! -e "$entered" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$entered" ]

  run bash "$REPO/$LEDGER_UPDATE" "$REPO" PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 0 ]
  GAIA_NOTEBOOK_TREE="$REPO" run bash "$REPO/$NOTEBOOK_LIBRARY" register research mint-isolation active
  [ "$status" -eq 0 ]

  # Both writes landed while the allocation was still inside the hook.
  kill -0 "$allocation_pid"

  wait "$allocation_pid"
  [ "$(cat "$BATS_TEST_TMPDIR/next.out")" = "SPEC-001" ]
  [ "$(jq -r '[.items[] | select(.kind == "plan")][0].status' "$REPO/.notebook/catalog.json")" = "merged" ]
  [ "$(jq -r '[.items[] | select(.kind == "research")][0].id' "$REPO/.notebook/catalog.json")" = "mint-isolation" ]
  [ "$(_row_field "$REPO" SPEC-001 reservation)" = "reserved" ]
}

# --- Tree selector ------------------------------------------------------------

@test "6: a fixture operand keeps archive and ledger-update away from the real checkout's notebook" {
  real_notebook="$(GAIA_NOTEBOOK_TREE="$REAL_ROOT" bash "$REAL_ROOT/$NOTEBOOK_LIBRARY" root)"
  before="$(_snapshot "$real_notebook")"
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001 --seed-spec SPEC-002 draft)"
  _close_row spec:SPEC-001 gaia-spec

  run bash "$REPO/$ARCHIVE_MERGED" "$REPO"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.notebook/specs/SPEC-001" ]
  run bash "$REPO/$LEDGER_UPDATE" "$REPO" SPEC-002 '{"status":"ready"}'
  [ "$status" -eq 0 ]
  [ "$(_row_field "$REPO" SPEC-002 status)" = "ready" ]

  [ "$(_snapshot "$real_notebook")" = "$before" ]
}
