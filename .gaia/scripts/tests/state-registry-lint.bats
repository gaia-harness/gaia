#!/usr/bin/env bats
#
# The state-registry lint: every `.entries[]` row must declare a valid
# `retention` and no legacy `reaped_by`, with unique ids.
#
# Each failing case is the committed registry with exactly one jq mutation,
# so a red result proves the lint caught that defect and nothing else. The
# input-set size is asserted against the registry itself, and one case
# strips retention from the last row so a lint that stops early still fails.
#
# Run under bash 5: `.gaia/scripts/bats5.sh .gaia/scripts/tests/state-registry-lint.bats`.
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
  LINT_SCRIPT="$SCRIPT_DIRECTORY/state-registry-lint.sh"
  COMMITTED_REGISTRY="$REPO_ROOT/.gaia/state-registry.json"
  SCRATCH_REGISTRY="$BATS_TEST_TMPDIR/registry.json"
}

# mutate_registry <jq-filter> [jq-args...]: writes the committed registry with
# one mutation applied to $SCRATCH_REGISTRY.
mutate_registry() {
  local filter="$1"
  shift
  jq "$@" "$filter" "$COMMITTED_REGISTRY" >"$SCRATCH_REGISTRY"
}

# Reads the real committed registry, so a registry edit alone selects this suite.
# bats test_tags=whole-tree
@test "the committed registry lints clean, with or without an argument, and the input set is non-empty" {
  local row_count
  row_count="$(jq '.entries | length' "$COMMITTED_REGISTRY")"
  [ "$row_count" -gt 0 ]
  run bash "$LINT_SCRIPT" "$COMMITTED_REGISTRY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=whole-tree
@test "a registry row defect is named: missing retention, unknown class, legacy reaped_by, duplicate id" {
  local row_count first_id last_id
  row_count="$(jq '.entries | length' "$COMMITTED_REGISTRY")"
  first_id="$(jq -r '.entries[0].id' "$COMMITTED_REGISTRY")"
  last_id="$(jq -r '.entries[-1].id' "$COMMITTED_REGISTRY")"

  mutate_registry 'del(.entries[0].retention)'
  run bash "$LINT_SCRIPT" "$SCRATCH_REGISTRY"
  [ "$status" -eq 1 ] || { echo "first row without retention: status $status"; return 1; }
  [ "$output" = "$first_id: missing retention" ] || { echo "first row without retention: '$output'"; return 1; }

  mutate_registry 'del(.entries[-1].retention)'
  run bash "$LINT_SCRIPT" "$SCRATCH_REGISTRY"
  [ "$status" -eq 1 ] || { echo "last row without retention: status $status"; return 1; }
  [ "$output" = "$last_id: missing retention" ] || { echo "last row without retention: '$output'"; return 1; }

  # Every row was checked: removing retention from all of them yields one
  # violation line per row.
  mutate_registry 'del(.entries[].retention)'
  run bash "$LINT_SCRIPT" "$SCRATCH_REGISTRY"
  [ "$status" -eq 1 ] || { echo "no row with retention: status $status"; return 1; }
  [ "${#lines[@]}" -eq "$row_count" ] || { echo "no row with retention: ${#lines[@]} lines"; return 1; }

  mutate_registry '.entries[0].retention = {"class": "sometimes"}'
  run bash "$LINT_SCRIPT" "$SCRATCH_REGISTRY"
  [ "$status" -eq 1 ] || { echo "unknown class: status $status"; return 1; }
  [ "$output" = "$first_id: unknown class \"sometimes\"" ] || { echo "unknown class: '$output'"; return 1; }

  mutate_registry '.entries[0].reaped_by = "an old prose reaper"'
  run bash "$LINT_SCRIPT" "$SCRATCH_REGISTRY"
  [ "$status" -eq 1 ] || { echo "legacy reaped_by: status $status"; return 1; }
  [ "${lines[0]}" = "$first_id: carries the legacy reaped_by field; retention replaces it" ] || { echo "legacy reaped_by: '$output'"; return 1; }
  [ "${#lines[@]}" -eq 1 ] || { echo "legacy reaped_by: ${#lines[@]} lines"; return 1; }

  mutate_registry '.entries[1].id = $id' --arg id "$first_id"
  run bash "$LINT_SCRIPT" "$SCRATCH_REGISTRY"
  [ "$status" -eq 1 ] || { echo "duplicate id: status $status"; return 1; }
  [ "$output" = "$first_id: duplicate row id" ] || { echo "duplicate id: '$output'"; return 1; }
}

# bats test_tags=whole-tree,protected
@test "a protected row must be keep or branch-spent with days 7" {
  local expected="audit-loop-state: a protected/ row must be keep, or branch-spent with days 7"

  mutate_registry '(.entries[] | select(.id == "audit-loop-state") | .retention) = {"class": "age", "days": 30}'
  run bash "$LINT_SCRIPT" "$SCRATCH_REGISTRY"
  [ "$status" -eq 1 ]
  [ "$output" = "$expected" ]

  mutate_registry '(.entries[] | select(.id == "audit-loop-state") | .retention) = {"class": "branch-spent", "key": "audit-loop", "days": 1}'
  run bash "$LINT_SCRIPT" "$SCRATCH_REGISTRY"
  [ "$status" -eq 1 ]
  [ "$output" = "$expected" ]

  # The two allowed shapes pass: keep, and branch-spent with days 7.
  mutate_registry '(.entries[] | select(.id == "audit-loop-state") | .retention) = {"class": "keep"}'
  run bash "$LINT_SCRIPT" "$SCRATCH_REGISTRY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  jq -e '.entries[] | select(.id == "checkpoint-override") | .retention.class == "keep"' "$COMMITTED_REGISTRY" >/dev/null
  run bash "$LINT_SCRIPT" "$COMMITTED_REGISTRY"
  [ "$status" -eq 0 ]
}

@test "exit 2 when the registry is missing, not JSON, or has no entries array" {
  run bash "$LINT_SCRIPT" "$BATS_TEST_TMPDIR/no-such-registry.json"
  [ "$status" -eq 2 ] || { echo "missing registry: status $status"; return 1; }
  printf 'not json {' >"$SCRATCH_REGISTRY"
  run bash "$LINT_SCRIPT" "$SCRATCH_REGISTRY"
  [ "$status" -eq 2 ] || { echo "not JSON: status $status"; return 1; }
  printf '{"residue": []}' >"$SCRATCH_REGISTRY"
  run bash "$LINT_SCRIPT" "$SCRATCH_REGISTRY"
  [ "$status" -eq 2 ] || { echo "no entries array: status $status"; return 1; }
}

# build_fixture_trees: a fixture main checkout whose committed registry is
# invalid and a linked worktree whose registry is valid, each holding its own
# copy of the lint and its libraries.
build_fixture_trees() {
  FIXTURE_MAIN="$BATS_TEST_TMPDIR/main"
  FIXTURE_WORKTREE="$BATS_TEST_TMPDIR/linked"
  mkdir -p "$FIXTURE_MAIN/.gaia/scripts"
  git -C "$BATS_TEST_TMPDIR" init -q -b main main
  git -C "$FIXTURE_MAIN" config user.email test@example.com
  git -C "$FIXTURE_MAIN" config user.name test
  cp "$SCRIPT_DIRECTORY"/*.sh "$FIXTURE_MAIN/.gaia/scripts/"
  jq 'del(.entries[0].retention)' "$COMMITTED_REGISTRY" >"$FIXTURE_MAIN/.gaia/state-registry.json"
  git -C "$FIXTURE_MAIN" add -A
  git -C "$FIXTURE_MAIN" commit -q -m fixture
  git -C "$FIXTURE_MAIN" worktree add -q -b linked "$FIXTURE_WORKTREE"
  cp "$COMMITTED_REGISTRY" "$FIXTURE_WORKTREE/.gaia/state-registry.json"
}

# bats test_tags=whole-tree
@test "the default registry is the one in the tree holding the script, not main's" {
  build_fixture_trees

  # Worktree copy, run from main's directory: lints the worktree's valid registry.
  run bash -c 'cd "$1" && bash "$2"' _ "$FIXTURE_MAIN" "$FIXTURE_WORKTREE/.gaia/scripts/state-registry-lint.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Main's copy, run from the worktree's directory: lints main's invalid registry.
  run bash -c 'cd "$1" && bash "$2"' _ "$FIXTURE_WORKTREE" "$FIXTURE_MAIN/.gaia/scripts/state-registry-lint.sh"
  [ "$status" -eq 1 ]
  [ -n "$output" ]
}
