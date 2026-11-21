#!/usr/bin/env bats
# End-to-end behavior of the spec scripts on the notebook: a fresh repo's first
# spec lives under the notebook and never under the old machine-local specs
# folder; the two reapers delete only the notebook's folder (from main and from
# a linked worktree), record a reap on the row, and refuse an id or a symlink
# that would reach outside it; the mint lock never stalls a plan or research
# write; and a fixture operand keeps every script away from the real checkout's
# notebook.
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
  REAL_ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  # shellcheck source=helpers/usage-gate.sh
  . "$HELPERS/usage-gate.sh"
  # The seeded merged_at and abandoned_at are fixed old stamps; collapsing the
  # window keeps every reap deterministic regardless of wall-clock time.
  export GAIA_SPEC_RETENTION_DAYS=0
  export GAIA_SPEC_FORCE_OFFLINE=1
  REPO=""
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

@test "the spec reapers delete the notebook folder from main or from a linked worktree, stamp a reap and leave decoys" {
  local row kind origin id script fixture tree seed
  for row in "merged|main" "merged|linked" "abandoned|main" "abandoned|linked"; do
    kind=${row%%|*}; origin=${row#*|}
    if [ "$kind" = merged ]; then
      id=SPEC-001
      script="$ARCHIVE_MERGED"
      seed=(--seed-spec-merged-folder "$id")
    else
      id=SPEC-002
      script="$ARCHIVE_ABANDONED"
      seed=(--seed-spec-abandoned-folder "$id")
    fi
    if [ "$origin" = linked ]; then
      fixture="$("$HELPERS/tmp-notebook-repo.sh" "${seed[@]}" --worktree wt)"
      REPO="$(printf '%s\n' "$fixture" | sed -n 1p)"
      tree="$(printf '%s\n' "$fixture" | sed -n 2p)"
    else
      REPO="$("$HELPERS/tmp-notebook-repo.sh" "${seed[@]}")"
      tree="$REPO"
    fi
    if [ "$kind" = merged ]; then _close_row "spec:$id" gaia-spec; fi
    _plant_decoys "$tree" "$id"

    run bash "$tree/$script" "$tree"
    [ "$status" -eq 0 ] || { echo "row $row: status $status"; return 1; }
    [ ! -e "$REPO/.notebook/specs/$id" ] || { echo "row $row: notebook folder survived"; return 1; }
    [ "$(_row_field "$REPO" "$id" status)" = "$kind" ] || { echo "row $row: row status changed"; return 1; }
    [ "$(jq -r '.items[0].reap.by' "$REPO/.notebook/catalog.json")" = "$(basename "$script")" ] || { echo "row $row: reap.by wrong"; return 1; }
    [ "$(jq -r '.items[0].reap.at | type' "$REPO/.notebook/catalog.json")" = "string" ] || { echo "row $row: reap.at missing"; return 1; }
    _assert_decoys "$tree" "$id" || { echo "row $row: a decoy was removed"; return 1; }
    rm -rf "$REPO" "${REPO}-wt"
  done
  REPO=""
}

# --- Path containment ---------------------------------------------

# _traversal_row <id> <status> <stamp field>: a catalog row whose id climbs out
# of the specs folder.
_traversal_row() {
  jq -cn --arg id "$1" --arg status "$2" --arg stamp_field "$3" \
    '{kind: "spec", id: $id, path: ("specs/" + $id), status: $status,
      subject: "traversal", created_at: "2026-01-01T00:00:00Z",
      status_changed_at: "2026-01-01T00:00:00Z"} + {($stamp_field): "2026-01-01T00:00:00Z"}'
}

# bats test_tags=protected
@test "the spec reapers skip a row whose id climbs out of the specs folder and refuse a symlinked spec folder, leaving everything outside intact" {
  local row kind id script outside file
  for row in "merged|SPEC-001/../../x" "abandoned|SPEC-001/../../x" "merged|.." "abandoned|.."; do
    kind=${row%%|*}; id=${row#*|}
    if [ "$kind" = merged ]; then
      script="$ARCHIVE_MERGED"
      REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-merged-folder SPEC-001 --seed-row "$(_traversal_row "$id" merged merged_at)")"
      _close_row "spec:$id" gaia-spec
    else
      script="$ARCHIVE_ABANDONED"
      REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec-folder SPEC-001 draft --seed-row "$(_traversal_row "$id" abandoned abandoned_at)")"
    fi
    mkdir -p "$REPO/.notebook/x"
    printf 'keep\n' > "$REPO/.notebook/x/keep.txt"

    run --separate-stderr bash "$REPO/$script" "$REPO"
    [ "$status" -eq 0 ] || { echo "row $row: status $status"; return 1; }
    [ -n "$stderr" ] || { echo "row $row: nothing on stderr"; return 1; }
    [ -f "$REPO/.notebook/x/keep.txt" ] || { echo "row $row: a file outside the specs folder was removed"; return 1; }
    [ -d "$REPO/.notebook/specs/SPEC-001" ] || { echo "row $row: the spec folder was removed"; return 1; }
    [ -f "$REPO/.notebook/catalog.json" ] || { echo "row $row: the catalog was removed"; return 1; }
    rm -rf "$REPO"
  done

  for kind in merged abandoned; do
    outside="$BATS_TEST_TMPDIR/outside-$kind"
    REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 "$kind")"
    mkdir -p "$outside" "$REPO/.notebook/specs"
    if [ "$kind" = merged ]; then
      script="$ARCHIVE_MERGED"
      printf -- '---\nspec_id: SPEC-001\nstatus: specified\nimmutable: true\n---\n' > "$outside/SPEC.md"
      printf -- '---\nwiki_promote_default: ask\nwiki_promote_targets: []\n---\n# SPEC-001\n\nBody.\n' > "$outside/SUMMARY.md"
      _close_row spec:SPEC-001 gaia-spec
    else
      script="$ARCHIVE_ABANDONED"
      printf 'keep\n' > "$outside/AUDIT.md"
    fi
    ln -s "$outside" "$REPO/.notebook/specs/SPEC-001"

    run --separate-stderr bash "$REPO/$script" "$REPO"
    [ "$status" -eq 0 ] || { echo "symlink $kind: status $status"; return 1; }
    [ -n "$stderr" ] || { echo "symlink $kind: nothing on stderr"; return 1; }
    for file in "$outside"/*; do
      [ -f "$file" ] || { echo "symlink $kind: target file removed"; return 1; }
    done
    [ -L "$REPO/.notebook/specs/SPEC-001" ] || { echo "symlink $kind: the link was removed"; return 1; }
    [ "$(_row_field "$REPO" SPEC-001 reap)" = "null" ] || { echo "symlink $kind: a reap was stamped"; return 1; }
    rm -rf "$REPO"
  done
  REPO=""
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
