#!/usr/bin/env bats
# Tests for notebook/move.sh run and check: the one-time move of specs, plans
# and research into the notebook. Fixtures are planted directly in the
# pre-notebook layout, which this suite exists to describe, inside throwaway
# repositories; the move is never pointed at the real checkout.
#
# Every invocation puts a recording rm shim first on PATH: the move must never
# delete, and teardown fails any test during which the shim was called.

# Each @test body is its own subshell and several build REPO inline, which the
# linter reads as a lost modification; the shim bodies are written as literal
# single-quoted shell text on purpose.
# shellcheck disable=SC2030,SC2031,SC2016
bats_require_minimum_version 1.5.0

# Builds the throwaway fixture repository the suite acts on.
_fixture_repository() {
  "$BATS_TEST_DIRNAME/../../tests/lib/helpers/tmp-notebook-repo.sh" "$@"
}

setup() {
  SHIM_DIRECTORY="$BATS_TEST_TMPDIR/shims"
  RM_CALLS="$BATS_TEST_TMPDIR/rm-calls"
  mkdir -p "$SHIM_DIRECTORY"
  printf '#!/bin/sh\necho "$@" >> "%s"\nexit 0\n' "$RM_CALLS" > "$SHIM_DIRECTORY/rm"
  chmod +x "$SHIM_DIRECTORY/rm"
  export GAIA_NOTEBOOK_MEMORY_DIR="$BATS_TEST_TMPDIR/memory-absent"
  REPO=""
}

teardown() {
  local calls=""
  [ -f "$RM_CALLS" ] && calls="$(cat "$RM_CALLS")"
  [ -n "$REPO" ] && command rm -rf "$REPO" "$REPO-"* "$REPO.git"
  if [ -n "$calls" ]; then
    echo "rm was invoked during the test: $calls" >&2
    return 1
  fi
}

# Runs the move from the fixture, with the rm shim first on PATH.
_move() {
  env PATH="$SHIM_DIRECTORY:$PATH" GAIA_NOTEBOOK_TREE="${MOVE_TREE:-$REPO}" \
    bash "$REPO/.gaia/scripts/notebook/move.sh" "$@"
}

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# One line per regular file under <root>/<kind>: "<kind>/<relative path> <sha256>".
# The frozen ledger backup maps back to its original name; lock files the move
# itself creates are not content.
_kind_manifest() {
  local root="$1" kind="$2" file relative
  [ -d "$root/$kind" ] || return 0
  find "$root/$kind" -type f | LC_ALL=C sort | while IFS= read -r file; do
    relative="${file#"$root/$kind/"}"
    case "${relative##*/}" in specs.lock) continue ;; esac
    relative="${relative//ledger.pre-notebook.json/ledger.json}"
    printf '%s/%s %s\n' "$kind" "$relative" "$(_sha256 "$file")"
  done
}

_legacy_manifest() {
  local kind
  for kind in specs plans research; do _kind_manifest "$REPO/.gaia/local" "$kind"; done | LC_ALL=C sort
}

_notebook_manifest() {
  local kind
  for kind in specs plans research; do _kind_manifest "$REPO/.notebook" "$kind"; done | LC_ALL=C sort
}

# Every file in the fixture except git's own store, with its checksum.
_tree_manifest() {
  find "$REPO" -path "$REPO/.git" -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s %s\n' "$file" "$(_sha256 "$file")"
  done
}

_plant_research_folder() {
  local name="$1"
  mkdir -p "$REPO/.gaia/local/research/$name/sub/deep"
  printf '# %s\n' "$name" > "$REPO/.gaia/local/research/$name/README.md"
  printf 'nested\n' > "$REPO/.gaia/local/research/$name/sub/deep/file.txt"
  printf '\000\001\377binary' > "$REPO/.gaia/local/research/$name/blob.dat"
  printf 'a,b\n' > "$REPO/.gaia/local/research/$name/data.csv"
  printf 'hidden\n' > "$REPO/.gaia/local/research/$name/.hidden"
  chmod 750 "$REPO/.gaia/local/research/$name/data.csv"
}

# Plants the pre-notebook layout under the fixture.
_plant_legacy() {
  local local_directory="$REPO/.gaia/local"
  mkdir -p "$local_directory/specs/SPEC-001/plan" "$local_directory/specs/SPEC-002" \
    "$local_directory/specs/SPEC-004" "$local_directory/specs/archived/SPEC-000" \
    "$local_directory/plans/PLAN-001" "$local_directory/plans/old-slug-plan" \
    "$local_directory/plans/archived/PLAN-000"
  printf -- '---\nspec_id: SPEC-001\nstatus: specified\nlineage: [research:alpha-2026-01-01, issue:5]\n---\n\n# one\n' \
    > "$local_directory/specs/SPEC-001/SPEC.md"
  printf 'progress\n' > "$local_directory/specs/SPEC-001/plan/PROGRESS.md"
  printf '\000\001\377' > "$local_directory/specs/SPEC-001/plan/blob.bin"
  printf '# audit\n' > "$local_directory/specs/SPEC-002/AUDIT.md"
  printf -- '---\nspec_id: SPEC-004\nstatus: specified\nlineage: []\n---\n' > "$local_directory/specs/SPEC-004/SPEC.md"
  printf 'old\n' > "$local_directory/specs/archived/SPEC-000/SUMMARY.md"
  printf 'plan one\n' > "$local_directory/plans/PLAN-001/PROGRESS.md"
  printf 'slug plan\n' > "$local_directory/plans/old-slug-plan/PROGRESS.md"
  printf 'old plan\n' > "$local_directory/plans/archived/PLAN-000/SUMMARY.md"
  cat > "$local_directory/specs/ledger.json" <<'JSON'
{"version":1,"specs":[
{"id":"SPEC-001","allocated_at":"2026-01-02T00:00:00Z","source":"allocated","status":"merged","merged_at":"2026-01-05T00:00:00Z","reservation":"pushed","subject":"one","custom_flag":{"keep":true}},
{"id":"SPEC-002","allocated_at":"2026-01-03T00:00:00Z","source":"adopted","status":"abandoned","abandoned_at":"2026-01-04T00:00:00Z","subject":"two"},
{"id":"SPEC-003","allocated_at":"2026-01-06T00:00:00Z","source":"allocated","status":"draft","subject":"three"},
{"id":"SPEC-004","allocated_at":"2026-01-07T00:00:00Z","source":"allocated","status":"draft","subject":"four"}]}
JSON
  cat > "$local_directory/plans/ledger.json" <<'JSON'
{"version":1,"plans":[
{"id":"PLAN-001","allocated_at":"2026-01-08T00:00:00Z","source":"allocated","status":"merged","merged_at":"2026-01-09T00:00:00Z","subject":"plan one"},
{"id":"PLAN-002","allocated_at":"2026-01-10T00:00:00Z","source":"allocated","status":"ready","pr_number":7,"subject":"plan two"}]}
JSON
  _plant_research_folder alpha-2026-01-01
  _plant_research_folder beta
  printf 'loose\n' > "$local_directory/research/notes.txt"
}

_fixture_with_legacy() {
  REPO="$(_fixture_repository --no-catalog)"
  _plant_legacy
}

@test "check exits 3 while the move is pending and 0 after it" {
  _fixture_with_legacy
  run _move check
  [ "$status" -eq 3 ]
  run _move run
  [ "$status" -eq 0 ]
  run _move check
  [ "$status" -eq 0 ]
}

@test "check exits 0 on a machine with nothing to move" {
  REPO="$(_fixture_repository --no-catalog)"
  run _move check
  [ "$status" -eq 0 ]
}

@test "a usage error exits 2" {
  _fixture_with_legacy
  run _move bogus
  [ "$status" -eq 2 ]
  run _move
  [ "$status" -eq 2 ]
}

@test "the move relocates every item by rename and folds both ledgers into the catalog" {
  _fixture_with_legacy
  local before after
  before="$(_legacy_manifest)"
  [ "$(printf '%s\n' "$before" | wc -l | tr -d ' ')" -ge 15 ]

  run _move run
  [ "$status" -eq 0 ]

  # Every pre-move file exists exactly once across the notebook and the old roots.
  after="$( { _notebook_manifest; _legacy_manifest; } | LC_ALL=C sort)"
  [ "$before" = "$after" ]

  # Moved items sit at the same name in the notebook.
  [ -f "$REPO/.notebook/specs/SPEC-001/plan/blob.bin" ]
  [ -f "$REPO/.notebook/specs/SPEC-004/SPEC.md" ]
  [ -f "$REPO/.notebook/plans/PLAN-001/PROGRESS.md" ]
  [ -f "$REPO/.notebook/research/alpha-2026-01-01/sub/deep/file.txt" ]
  [ -f "$REPO/.notebook/research/notes.txt" ]
  [ ! -e "$REPO/.gaia/local/specs/SPEC-001" ]
  [ ! -e "$REPO/.gaia/local/research/beta" ]

  # Left in place: slug-named plan folder, archived/, ledger backups.
  [ -d "$REPO/.gaia/local/plans/old-slug-plan" ]
  [ -d "$REPO/.gaia/local/plans/archived/PLAN-000" ]
  [ -d "$REPO/.gaia/local/specs/archived/SPEC-000" ]
  [ -f "$REPO/.gaia/local/specs/ledger.pre-notebook.json" ]
  [ -f "$REPO/.gaia/local/plans/ledger.pre-notebook.json" ]
  [ ! -e "$REPO/.gaia/local/specs/ledger.json" ]
  [[ "$output" == *"left in place: .gaia/local/plans/old-slug-plan"* ]]
  [[ "$output" == *"left in place: .gaia/local/specs/archived"* ]]
  [[ "$output" == *"loose research file moved: research/notes.txt"* ]]
  [[ "$output" == *"moved research folders: 2"* ]]
  [[ "$output" == *"moved specs: 3"* ]]
  [[ "$output" == *"moved plans: 1"* ]]
}

@test "catalog rows map the ledger fields and the marker is written" {
  _fixture_with_legacy
  run _move run
  [ "$status" -eq 0 ]
  local catalog="$REPO/.notebook/catalog.json"
  jq -e '.move_complete.at | type == "string"' "$catalog"
  [ "$(jq '.items | length' "$catalog")" -eq 8 ]

  # SPEC-001: merged, so status_changed_at is merged_at; unknown field kept.
  jq -e '.items[] | select(.kind == "spec" and .id == "SPEC-001")
    | .created_at == "2026-01-02T00:00:00Z" and .status_changed_at == "2026-01-05T00:00:00Z"
      and .merged_at == "2026-01-05T00:00:00Z" and .source == "allocated" and .reservation == "pushed"
      and .custom_flag == {"keep": true} and .path == "specs/SPEC-001" and .status == "merged"
      and .subject == "one" and (has("allocated_at") | not)
      and .links.research == ["alpha-2026-01-01"]' "$catalog"
  # SPEC-002: abandoned, so status_changed_at is abandoned_at; source kept verbatim.
  jq -e '.items[] | select(.id == "SPEC-002")
    | .created_at == "2026-01-03T00:00:00Z" and .status_changed_at == "2026-01-04T00:00:00Z"
      and .source == "adopted" and .abandoned_at == "2026-01-04T00:00:00Z"' "$catalog"
  # SPEC-004: neither, so allocated_at; an empty lineage sets no links.
  jq -e '.items[] | select(.id == "SPEC-004")
    | .status_changed_at == "2026-01-07T00:00:00Z" and (has("links") | not)' "$catalog"
  # Plan rows.
  jq -e '.items[] | select(.kind == "plan" and .id == "PLAN-001")
    | .created_at == "2026-01-08T00:00:00Z" and .status_changed_at == "2026-01-09T00:00:00Z" and .path == "plans/PLAN-001"' "$catalog"
  jq -e '.items[] | select(.kind == "plan" and .id == "PLAN-002")
    | .status_changed_at == "2026-01-10T00:00:00Z" and .pr_number == 7' "$catalog"
  # One untagged row per research folder, none for the loose file.
  [ "$(jq '[.items[] | select(.kind == "research")] | length' "$catalog")" -eq 2 ]
  jq -e '.items[] | select(.kind == "research" and .id == "beta")
    | .status == "untagged" and .path == "research/beta" and .created_at == .status_changed_at' "$catalog"

  # Rows with no folder carry the pre-catalog reap record; the rest carry none.
  [ "$(jq -c '[.items[] | select(.reap.by == "pre-catalog") | .id] | sort' "$catalog")" = '["PLAN-002","SPEC-003"]' ]
  jq -e '.items[] | select(.id == "SPEC-003") | .reap == {"at": null, "by": "pre-catalog"}' "$catalog"
  [ "$(jq '[.items[] | select(has("reap"))] | length' "$catalog")" -eq 2 ]
}

@test "files keep their content and mode through the move" {
  _fixture_with_legacy
  local mode_before mode_after
  mode_before="$(_mode "$REPO/.gaia/local/research/beta/data.csv")"
  [ "$mode_before" = 750 ]
  run _move run
  [ "$status" -eq 0 ]
  mode_after="$(_mode "$REPO/.notebook/research/beta/data.csv")"
  [ "$mode_after" = 750 ]
  [ -f "$REPO/.notebook/research/beta/.hidden" ]
  [ -f "$REPO/.notebook/research/beta/blob.dat" ]
  [ -f "$REPO/.notebook/research/beta/sub/deep/file.txt" ]
  [ ! -e "$REPO/.gaia/local/research/beta" ]
  [ ! -e "$REPO/.gaia/local/specs/SPEC-001" ]
  [ -f "$REPO/.notebook/specs/SPEC-001/plan/PROGRESS.md" ]
}

@test "reconcile reports none of the folded rows that carry the pre-catalog record" {
  _fixture_with_legacy
  run _move run
  [ "$status" -eq 0 ]
  run env GAIA_NOTEBOOK_TREE="$REPO" bash "$REPO/.gaia/scripts/notebook/reconcile.sh"
  [ "$status" -eq 0 ]
  # The sweep did look at the notebook: it names the moved loose file.
  [[ "$output" == *"research/notes.txt: loose file"* ]]
  [[ "$output" != *"SPEC-003"* ]] || return 1
  [[ "$output" != *"PLAN-002"* ]] || return 1
  true
}

@test "reconcile does report a row without a folder once its reap record is gone" {
  _fixture_with_legacy
  run _move run
  [ "$status" -eq 0 ]
  local catalog="$REPO/.notebook/catalog.json" stripped
  stripped="$(jq 'del(.items[].reap)' "$catalog")"
  printf '%s\n' "$stripped" > "$catalog"
  run env GAIA_NOTEBOOK_TREE="$REPO" bash "$REPO/.gaia/scripts/notebook/reconcile.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SPEC-003: row without folder"* ]]
}

@test "a both-present collision keeps both copies and a second run changes nothing" {
  _fixture_with_legacy
  mkdir -p "$REPO/.notebook/research/beta" "$REPO/.notebook/specs/SPEC-002"
  printf 'notebook copy\n' > "$REPO/.notebook/research/beta/README.md"
  printf 'notebook audit\n' > "$REPO/.notebook/specs/SPEC-002/AUDIT.md"
  local before_copy old_before
  before_copy="$(_sha256 "$REPO/.notebook/research/beta/README.md")"
  old_before="$(_sha256 "$REPO/.gaia/local/research/beta/README.md")"

  run _move run
  [ "$status" -eq 0 ]
  [ "$(_sha256 "$REPO/.notebook/research/beta/README.md")" = "$before_copy" ]
  [ "$(_sha256 "$REPO/.gaia/local/research/beta/README.md")" = "$old_before" ]
  [ ! -e "$REPO/.notebook/research/beta/blob.dat" ]
  [ -f "$REPO/.gaia/local/specs/SPEC-002/AUDIT.md" ]
  [[ "$output" == *"collision, both copies kept (the notebook copy is untouched): .gaia/local/research/beta"* ]]
  [[ "$output" == *"collision, both copies kept (the notebook copy is untouched): .gaia/local/specs/SPEC-002"* ]]
  [[ "$output" == *"collisions: 2"* ]]

  local tree_after_first
  tree_after_first="$(_tree_manifest)"
  run _move run
  [ "$status" -eq 0 ]
  [ "$(_tree_manifest)" = "$tree_after_first" ]
}

# Counts every rename out of the old roots and fails the one after <limit>.
_install_failing_mv() {
  local limit="$1"
  local real_mv
  real_mv="$(command -v mv)"
  printf '%s\n' '#!/bin/sh' \
    'case "$*" in' \
    '  */.gaia/local/*)' \
    "    count=\$(cat \"$BATS_TEST_TMPDIR/mv-count\" 2>/dev/null || echo 0)" \
    "    echo \$((count + 1)) > \"$BATS_TEST_TMPDIR/mv-count\"" \
    "    if [ \"\$count\" -ge \"$limit\" ]; then echo 'mv shim: injected failure' >&2; exit 1; fi" \
    '    ;;' \
    'esac' \
    "exec \"$real_mv\" \"\$@\"" > "$SHIM_DIRECTORY/mv"
  chmod +x "$SHIM_DIRECTORY/mv"
  command rm -f "$BATS_TEST_TMPDIR/mv-count"
}

_remove_failing_mv() {
  command rm -f "$SHIM_DIRECTORY/mv"
}

# The catalog without the stamps that legitimately differ between two runs.
_normalized_catalog() {
  jq -S 'del(.move_complete) | .items |= (map(if .kind == "research" then del(.created_at, .status_changed_at) else . end) | sort_by(.kind, .id))' \
    "$REPO/.notebook/catalog.json"
}

@test "a move interrupted after the fold or part way through a re-run converges to the uninterrupted end state" {
  # Reference: one uninterrupted run, counting how many renames it makes.
  _fixture_with_legacy
  _install_failing_mv 100000
  run _move run
  [ "$status" -eq 0 ]
  local total reference_catalog reference_files
  total="$(cat "$BATS_TEST_TMPDIR/mv-count")"
  [ "$total" -ge 8 ]
  reference_catalog="$(_normalized_catalog)"
  reference_files="$( { _notebook_manifest; _legacy_manifest; } | LC_ALL=C sort)"
  _remove_failing_mv
  command rm -rf "$REPO" "$REPO-"*

  local cut
  for cut in 0 3 $((total - 1)); do
    _fixture_with_legacy
    _install_failing_mv "$cut"
    run _move run
    [ "$status" -eq 1 ]
    # The marker is written last, so an interrupted move never reads as done.
    [ "$(jq 'has("move_complete")' "$REPO/.notebook/catalog.json")" = false ]
    # The partial state lost no file.
    [ "$( { _notebook_manifest; _legacy_manifest; } | LC_ALL=C sort)" = "$reference_files" ]

    _remove_failing_mv
    run _move run
    [ "$status" -eq 0 ]
    [[ "$output" == *"collisions: 0"* ]]
    [ "$(_normalized_catalog)" = "$reference_catalog" ]
    [ "$( { _notebook_manifest; _legacy_manifest; } | LC_ALL=C sort)" = "$reference_files" ]
    jq -e 'has("move_complete")' "$REPO/.notebook/catalog.json"
    command rm -rf "$REPO" "$REPO-"*
  done
  REPO=""
}

@test "the move refuses while a linked worktree lacks the notebook library, naming each" {
  _fixture_with_legacy
  local empty_tree stale_commit tree_before
  empty_tree="$(git -C "$REPO" hash-object -t tree /dev/null)"
  stale_commit="$(git -C "$REPO" commit-tree "$empty_tree" -m stale)"
  git -C "$REPO" worktree add --quiet -b stale-one "$REPO-stale-one" "$stale_commit"
  git -C "$REPO" worktree add --quiet -b stale-two "$REPO-stale-two" "$stale_commit"
  tree_before="$(_tree_manifest)"

  run _move run
  [ "$status" -eq 9 ]
  [[ "$output" == *"worktree $REPO-stale-one (branch stale-one)"* ]]
  [[ "$output" == *"worktree $REPO-stale-two (branch stale-two)"* ]]
  [[ "$output" == *"catch that branch up with main, or remove the worktree"* ]]
  [ "$(_tree_manifest)" = "$tree_before" ]
  [ -d "$REPO/.gaia/local/specs/SPEC-001" ]
}

@test "a linked worktree that carries the library does not block the move" {
  _fixture_with_legacy
  git -C "$REPO" worktree add --quiet -b current-one "$REPO-current-one"
  run _move run
  [ "$status" -eq 0 ]
}

@test "the move refuses to run from a linked worktree" {
  _fixture_with_legacy
  git -C "$REPO" worktree add --quiet -b linked-one "$REPO-linked-one"
  local tree_before
  tree_before="$(_tree_manifest)"
  MOVE_TREE="$REPO-linked-one" run _move run
  [ "$status" -eq 9 ]
  [[ "$output" == *"run from the main checkout"* ]]
  [ "$(_tree_manifest)" = "$tree_before" ]
}

@test "the move refuses when .notebook is not gitignored" {
  _fixture_with_legacy
  printf '.gaia/local\n' > "$REPO/.gitignore"
  local tree_before
  tree_before="$(_tree_manifest)"
  run _move run
  [ "$status" -eq 9 ]
  [[ "$output" == *"does not ignore .notebook"* ]]
  [[ "$output" == *"add the line .notebook to its .gitignore"* ]]
  [ "$(_tree_manifest)" = "$tree_before" ]
}

@test "the move refuses while a RUNNING sentinel exists under the old specs root" {
  _fixture_with_legacy
  : > "$REPO/.gaia/local/specs/SPEC-001/plan/RUNNING"
  local tree_before
  tree_before="$(_tree_manifest)"
  run _move run
  [ "$status" -eq 9 ]
  [[ "$output" == *".gaia/local/specs/SPEC-001/plan/RUNNING"* ]]
  [[ "$output" == *"a run is live"* ]]
  [ "$(_tree_manifest)" = "$tree_before" ]
}

@test "the move refuses when an old root is on a different device" {
  _fixture_with_legacy
  local real_stat
  real_stat="$(command -v stat)"
  printf '%s\n' '#!/bin/sh' \
    'for last in "$@"; do :; done' \
    'case "$last" in */.gaia/local/specs) echo 999999; exit 0 ;; esac' \
    "exec \"$real_stat\" \"\$@\"" > "$SHIM_DIRECTORY/stat"
  chmod +x "$SHIM_DIRECTORY/stat"
  local tree_before
  tree_before="$(_tree_manifest)"
  run _move run
  [ "$status" -eq 9 ]
  [[ "$output" == *"different device"* ]]
  [[ "$output" == *".gaia/local/specs"* ]]
  [ "$(_tree_manifest)" = "$tree_before" ]
}

@test "the move refuses an unreadable legacy ledger before moving anything" {
  _fixture_with_legacy
  printf 'not json' > "$REPO/.gaia/local/plans/ledger.json"
  local tree_before
  tree_before="$(_tree_manifest)"
  run _move run
  [ "$status" -eq 9 ]
  [[ "$output" == *"plans/ledger.json is not a JSON object"* ]]
  [ "$(_tree_manifest)" = "$tree_before" ]
}

@test "the report names run states and notebook files that cite an old location" {
  _fixture_with_legacy
  mkdir -p "$REPO/.gaia/local/runs/some-branch"
  printf 'see .gaia/local/specs/SPEC-001/SPEC.md\n' > "$REPO/.gaia/local/runs/some-branch/STATE.md"
  printf 'cite .gaia/local/research/beta/README.md\n' > "$REPO/.gaia/local/research/beta/CITES.md"
  run _move run
  [ "$status" -eq 0 ]
  [[ "$output" == *"run state names an old location: .gaia/local/runs/some-branch/STATE.md"* ]]
  [[ "$output" == *"notebook file names an old location: .notebook/research/beta/CITES.md"* ]]
}

@test "the report lists memory files and names the repoint command only when one qualifies" {
  _fixture_with_legacy
  local memory="$BATS_TEST_TMPDIR/memory"
  mkdir -p "$memory"
  printf 'plans live in .gaia/local/plans/ today\n' > "$memory/has-old.md"
  printf 'cache is .gaia/local/cache/x\n' > "$memory/clean.md"
  export GAIA_NOTEBOOK_MEMORY_DIR="$memory"
  run _move run
  [ "$status" -eq 0 ]
  [[ "$output" == *"memory file names an old location: $memory/has-old.md"* ]]
  [[ "$output" != *"clean.md"* ]] || return 1
  [[ "$output" == *"move.sh memory-repoint"* ]]
  # The move itself repoints nothing.
  grep -qF '.gaia/local/plans/' "$memory/has-old.md"
}

@test "no memory line appears when no memory file qualifies" {
  _fixture_with_legacy
  run _move run
  [ "$status" -eq 0 ]
  [[ "$output" != *"memory-repoint"* ]] || return 1
  true
}
