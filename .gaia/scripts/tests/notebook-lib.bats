#!/usr/bin/env bats
#
# Catalog suite for the notebook library (.gaia/scripts/notebook/): the
# catalog schema and its corrupt-catalog refusal, the readiness gate and the
# sourced primitives that bypass it, the gitignore precondition, register,
# update and rename semantics, and the unresolvable-main refusal. Paths,
# listing and the tree selector live in notebook-lib-paths.bats; locking and
# concurrent writers in notebook-lib-concurrency.bats.
#
# Every fixture is a throwaway git repository holding copies of the library
# and the two files it sources, at their real relative paths. Every library
# call names its tree through GAIA_NOTEBOOK_TREE or runs from inside the
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
  MOVE_COMMAND="bash .gaia/scripts/notebook/move.sh run"
  # shellcheck source=/dev/null
  source "$REPO/.gaia/scripts/notebook/legacy-roots.sh"
}

# make_repo <name> [no-ignore]: prints the physical path of a new fixture
# repository with the library committed, so a linked worktree carries it too.
make_repo() {
  local repository="$SCRATCH/$1" relative
  mkdir -p "$repository"
  git -C "$repository" init -q --initial-branch=main
  git -C "$repository" config user.email gaia-test@example.com
  git -C "$repository" config user.name "GAIA Test"
  git -C "$repository" config commit.gpgsign false
  : >"$SCRATCH/empty-excludes"
  git -C "$repository" config core.excludesFile "$SCRATCH/empty-excludes"
  if [ "${2:-}" != "no-ignore" ]; then
    printf '.notebook\n' >"$repository/.gitignore"
  else
    printf 'node_modules\n' >"$repository/.gitignore"
  fi
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

# notebook_sourced <shell text>: runs the text with the library sourced,
# against the fixture.
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

seed_old_stamps() {
  local updated
  updated="$(jq '.items |= map(. + {created_at: "2020-01-01T00:00:00Z", status_changed_at: "2020-01-01T00:00:00Z"})' "$CATALOG")"
  printf '%s\n' "$updated" >"$CATALOG"
}

plant_legacy_ledger() {
  local legacy_directory
  legacy_directory="$(gaia_notebook_legacy_root "$1" "$REPO")"
  mkdir -p "$legacy_directory"
  printf '{}\n' >"$legacy_directory/ledger.json"
}

# Every verb the dispatcher's usage line names, read from the library so a
# verb added there and missing here fails the coverage check below.
library_verbs() {
  run --separate-stderr bash "$LIBRARY" no-such-verb
  printf '%s\n' "$stderr" | sed -e 's/^[^{]*{//' -e 's/}[^}]*$//' | tr '|' '\n' \
    | sed -e 's/^ *//' | cut -d' ' -f1 | LC_ALL=C sort
}

# One valid invocation per verb that runs the readiness gate.
gated_invocations() {
  cat <<'EOF'
require-ready
path spec
get spec SPEC-001
list spec
folders spec
register research 2026-10-01-topic active
set-status research 2026-10-01-topic closed
update research 2026-10-01-topic {}
classify .notebook/specs/SPEC-001
EOF
}

@test "register then set-status keeps one research row and restamps the status change" {
  run notebook register research 2026-10-01-topic active
  [ "$status" -eq 0 ]
  [ "$(catalog_field '[.items[] | select(.kind == "research")] | length')" = 1 ]
  [ "$(catalog_field '.items[0].status')" = active ]
  [ "$(catalog_field '.items[0].created_at')" = "$(catalog_field '.items[0].status_changed_at')" ]
  [ "$(catalog_field '.items[0].path')" = research/2026-10-01-topic ]
  [ "$(catalog_field 'has("move_complete")')" = false ]
  seed_old_stamps
  run notebook set-status research 2026-10-01-topic closed
  [ "$status" -eq 0 ]
  [ "$(catalog_field '[.items[] | select(.kind == "research")] | length')" = 1 ]
  [ "$(catalog_field '.items[0].status')" = closed ]
  local changed created
  changed="$(catalog_field '.items[0].status_changed_at')"
  created="$(catalog_field '.items[0].created_at')"
  [ "$created" = "2020-01-01T00:00:00Z" ]
  [ "$changed" != "$created" ]
  [[ "$changed" > "$created" ]]
}

@test "registering an existing research row leaves it unchanged; an existing spec row refuses" {
  run notebook register research 2026-10-01-topic active
  [ "$status" -eq 0 ]
  local before
  before="$(file_digest "$CATALOG")"
  run notebook register research 2026-10-01-topic closed
  [ "$status" -eq 0 ]
  [ "$(file_digest "$CATALOG")" = "$before" ]
  run notebook register spec SPEC-001 draft
  [ "$status" -eq 0 ]
  before="$(file_digest "$CATALOG")"
  run notebook register spec SPEC-001 ready
  [ "$status" -eq 2 ]
  [ "$(file_digest "$CATALOG")" = "$before" ]
}

@test "the gated verb list covers every verb the dispatcher names" {
  local expected actual
  expected="$(library_verbs)"
  [ -n "$expected" ]
  actual="$({ gated_invocations | cut -d' ' -f1; printf 'root\nmove-state\n'; } | LC_ALL=C sort)"
  [ "$actual" = "$expected" ]
}

@test "a legacy specs or plans ledger without the move marker makes every gated verb exit 3 and create nothing" {
  local kind invocation count
  for kind in specs plans; do
    rm -rf "${SCRATCH:?}/$kind-repo"
    REPO="$(make_repo "$kind-repo")"
    LIBRARY="$REPO/.gaia/scripts/notebook/notebook-lib.sh"
    plant_legacy_ledger "$kind"
    count=0
    while IFS= read -r invocation; do
      # shellcheck disable=SC2086
      run --separate-stderr notebook $invocation
      [ "$status" -eq 3 ] || { echo "$kind: '$invocation' exited $status"; return 1; }
      [[ "$stderr" == *"$MOVE_COMMAND"* ]] || { echo "$kind: '$invocation' stderr: $stderr"; return 1; }
      [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
      [ ! -e "$REPO/.notebook" ] || { echo "$kind: '$invocation' created the notebook"; return 1; }
      count=$((count + 1))
    done < <(gated_invocations)
    [ "$count" -eq "$(gated_invocations | wc -l | tr -d ' ')" ]
    run notebook root
    [ "$status" -eq 0 ]
    run notebook move-state
    [ "$status" -eq 0 ]
    [ "$output" = pending ]
    [ ! -e "$REPO/.notebook" ]
  done
}

@test "a legacy ledger with the move marker lets verbs run; no ledger and no catalog creates a fresh catalog" {
  plant_legacy_ledger specs
  mkdir -p "$REPO/.notebook"
  printf '{"version":1,"move_complete":{"at":"2026-10-01T00:00:00Z"},"items":[]}\n' >"$CATALOG"
  run notebook register research 2026-10-01-topic active
  [ "$status" -eq 0 ]
  run notebook list spec
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]

  REPO="$(make_repo fresh)"
  LIBRARY="$REPO/.gaia/scripts/notebook/notebook-lib.sh"
  CATALOG="$REPO/.notebook/catalog.json"
  [ ! -e "$CATALOG" ]
  run notebook register research 2026-10-01-topic active
  [ "$status" -eq 0 ]
  [ "$(catalog_field 'has("move_complete")')" = false ]
  [ "$(catalog_field '.version')" = 1 ]
}

@test "sourced primitives bypass the readiness gate so the move can fold a legacy ledger" {
  plant_legacy_ledger specs
  run notebook_sourced '
    fold() {
      gaia_notebook_upsert spec SPEC-001 "{\"status\":\"draft\",\"source\":\"local\"}" &&
        gaia_notebook_upsert plan PLAN-001 "{\"status\":\"ready\"}"
    }
    gaia_notebook_with_catalog_lock fold || exit 10
    gaia_notebook_set_move_complete || exit 11
    gaia_notebook_memory_directory >/dev/null || exit 12'
  [ "$status" -eq 0 ]
  [ "$(catalog_field '.items | length')" = 2 ]
  [ "$(catalog_field '.items[] | select(.id == "SPEC-001") | .path')" = specs/SPEC-001 ]
  [ "$(catalog_field '.move_complete | type')" = object ]
  run notebook list spec
  [ "$status" -eq 0 ]
  run notebook require-ready
  [ "$status" -eq 0 ]
}

@test "a corrupt catalog makes list, register, update and set-status exit 4 and change nothing" {
  local corrupt_cases=(
    'not json at all'
    '{"version":2,"items":[]}'
    '{"version":1,"items":{}}'
    '{"version":1,"items":[{"kind":"widget","id":"x","status":"active"}]}'
  )
  local invocations=(
    'list research'
    'register research 2026-10-01-topic active'
    'update research 2026-10-01-topic {"status":"closed"}'
    'set-status research 2026-10-01-topic closed'
  )
  mkdir -p "$REPO/.notebook"
  local corrupt invocation before checked=0
  for corrupt in "${corrupt_cases[@]}"; do
    printf '%s\n' "$corrupt" >"$CATALOG"
    before="$(file_digest "$CATALOG")"
    for invocation in "${invocations[@]}"; do
      # shellcheck disable=SC2086
      run --separate-stderr notebook $invocation
      [ "$status" -eq 4 ] || { echo "'$corrupt' / '$invocation' exited $status"; return 1; }
      [[ "$stderr" == *GAIA_NOTEBOOK_CATALOG_CORRUPT* ]]
      [ "$(file_digest "$CATALOG")" = "$before" ]
      checked=$((checked + 1))
    done
  done
  [ "$checked" -eq $(( ${#corrupt_cases[@]} * ${#invocations[@]} )) ]
}

@test "the same verbs succeed on a valid catalog (red twin of the corrupt case)" {
  mkdir -p "$REPO/.notebook"
  printf '{"version":1,"items":[]}\n' >"$CATALOG"
  run notebook list research
  [ "$status" -eq 0 ]
  run notebook register research 2026-10-01-topic active
  [ "$status" -eq 0 ]
  run notebook update research 2026-10-01-topic '{"status":"closed"}'
  [ "$status" -eq 0 ]
  run notebook set-status research 2026-10-01-topic active
  [ "$status" -eq 0 ]
}

@test "register refuses with 5 and creates nothing when main does not ignore .notebook" {
  REPO="$(make_repo unignored no-ignore)"
  LIBRARY="$REPO/.gaia/scripts/notebook/notebook-lib.sh"
  run --separate-stderr notebook register research 2026-10-01-topic active
  [ "$status" -eq 5 ]
  [[ "$stderr" == *".notebook"* ]]
  [[ "$stderr" == *".gitignore"* ]]
  [ ! -e "$REPO/.notebook" ]
  printf '.notebook\n' >>"$REPO/.gitignore"
  run notebook register research 2026-10-01-topic active
  [ "$status" -eq 0 ]
  [ -f "$REPO/.notebook/catalog.json" ]
}

@test "update refuses a missing row with 6, merges onto an existing row, and refuses a non-canonical status" {
  run notebook update spec SPEC-001 '{"status":"ready"}'
  [ "$status" -eq 6 ]
  run notebook register spec SPEC-001 draft --subject "a subject" --extra '{"mystery":{"kept":true}}'
  [ "$status" -eq 0 ]
  seed_old_stamps
  run notebook update spec SPEC-001 '{"status":"ready"}'
  [ "$status" -eq 0 ]
  [ "$(catalog_field '.items[0].status')" = ready ]
  [ "$(catalog_field '.items[0].status_changed_at')" != "2020-01-01T00:00:00Z" ]
  [ "$(catalog_field '.items[0].created_at')" = "2020-01-01T00:00:00Z" ]
  [ "$(catalog_field '.items[0].mystery.kept')" = true ]
  [ "$(catalog_field '.items[0].subject')" = "a subject" ]
  seed_old_stamps
  run notebook update spec SPEC-001 '{"pr_number":12}'
  [ "$status" -eq 0 ]
  [ "$(catalog_field '.items[0].status_changed_at')" = "2020-01-01T00:00:00Z" ]
  run notebook update spec SPEC-001 '{"status":"merged","status_changed_at":"2021-01-01T00:00:00Z"}'
  [ "$status" -eq 0 ]
  [ "$(catalog_field '.items[0].status_changed_at')" = "2021-01-01T00:00:00Z" ]

  run notebook register plan PLAN-001 ready
  [ "$status" -eq 0 ]
  local before
  before="$(file_digest "$CATALOG")"
  run notebook update plan PLAN-001 '{"status":"draft"}'
  [ "$status" -eq 2 ]
  [ "$(file_digest "$CATALOG")" = "$before" ]
  run notebook update plan PLAN-001 '[1]'
  [ "$status" -eq 2 ]
  run notebook update plan PLAN-001 '{"id":"PLAN-002"}'
  [ "$status" -eq 2 ]
  [ "$(file_digest "$CATALOG")" = "$before" ]
}

@test "with the main root unresolvable every verb exits 1 and writes nothing" {
  local outside="$SCRATCH/not-a-repo" invocation count=0
  mkdir -p "$outside"
  run git -C "$outside" rev-parse --git-dir
  [ "$status" -ne 0 ]
  while IFS= read -r invocation; do
    # shellcheck disable=SC2086
    run in_directory "$outside" bash "$LIBRARY" $invocation
    [ "$status" -eq 1 ] || { echo "'$invocation' exited $status"; return 1; }
    count=$((count + 1))
  done < <(gated_invocations; printf 'root\nmove-state\n')
  [ "$count" -eq $(( $(gated_invocations | wc -l | tr -d ' ') + 2 )) ]
  [ -z "$(ls -A "$outside")" ]
  [ ! -e "$REPO/.notebook" ]
}

@test "rename re-keys a row in one write and refuses a taken, missing or invalid id" {
  run notebook register spec SPEC-003 draft --extra '{"source":"local","mystery":42}'
  [ "$status" -eq 0 ]
  run notebook_sourced 'gaia_notebook_rename spec SPEC-003 SPEC-004'
  [ "$status" -eq 0 ]
  [ "$(catalog_field '.items | length')" = 1 ]
  [ "$(catalog_field '.items[0].id')" = SPEC-004 ]
  [ "$(catalog_field '.items[0].path')" = specs/SPEC-004 ]
  [ "$(catalog_field '.items[0].renamed_from')" = SPEC-003 ]
  [ "$(catalog_field '.items[0].source')" = local ]
  [ "$(catalog_field '.items[0].mystery')" = 42 ]
  [ "$(catalog_field '.items[0].status')" = draft ]

  run notebook register spec SPEC-005 draft
  [ "$status" -eq 0 ]
  local before
  before="$(file_digest "$CATALOG")"
  run notebook_sourced 'gaia_notebook_rename spec SPEC-004 SPEC-005'
  [ "$status" -eq 2 ]
  [ "$(file_digest "$CATALOG")" = "$before" ]
  run notebook_sourced 'gaia_notebook_rename spec SPEC-009 SPEC-010'
  [ "$status" -eq 6 ]
  run notebook_sourced 'gaia_notebook_rename spec SPEC-004 SPEC-4'
  [ "$status" -eq 2 ]
  [ "$(file_digest "$CATALOG")" = "$before" ]
}

@test "register merges extra fields in one row and refuses reserved keys or a non-object" {
  run notebook_sourced 'gaia_notebook_register spec SPEC-005 draft "t" "" "{\"source\":\"local\",\"reservation\":\"provisional\"}"'
  [ "$status" -eq 0 ]
  [ "$(catalog_field '.items | length')" = 1 ]
  [ "$(catalog_field '.items[0].source')" = local ]
  [ "$(catalog_field '.items[0].reservation')" = provisional ]
  [ "$(catalog_field '.items[0].subject')" = t ]
  [ "$(catalog_field '.items[0] | has("links")')" = false ]
  local before extra
  before="$(file_digest "$CATALOG")"
  for extra in '{"status":"ready"}' '{"id":"SPEC-007"}' '[1]' 'not json'; do
    run notebook register spec SPEC-006 draft --extra "$extra"
    [ "$status" -eq 2 ] || { echo "$extra -> $status"; return 1; }
  done
  run notebook register spec SPEC-006 draft --links '"text"'
  [ "$status" -eq 2 ]
  run notebook register spec SPEC-006 abandoned-ish
  [ "$status" -eq 2 ]
  [ "$(file_digest "$CATALOG")" = "$before" ]
}

@test "get prints one row, list filters by status, and record_reap and snooze write their fields" {
  run notebook register research 2026-10-01-a active
  run notebook register research 2026-10-01-b closed
  run notebook get research 2026-10-01-a
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = active ]
  run notebook get research 2026-10-01-c
  [ "$status" -eq 1 ]
  run notebook list research --status closed
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.[].id] | join(",")')" = 2026-10-01-b ]
  run notebook list research --status bogus
  [ "$status" -eq 2 ]
  run notebook_sourced 'gaia_notebook_record_reap research 2026-10-01-b research-reaper && gaia_notebook_snooze 2026-10-01-a 2030-01-01T00:00:00Z'
  [ "$status" -eq 0 ]
  [ "$(catalog_field '.items[] | select(.id == "2026-10-01-b") | .reap.by')" = research-reaper ]
  [ "$(catalog_field '.items[] | select(.id == "2026-10-01-a") | .snoozed_until')" = 2030-01-01T00:00:00Z ]
}
