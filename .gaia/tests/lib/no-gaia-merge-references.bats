#!/usr/bin/env bats
#
# Repo-wide check: no tracked file outside the allowed set mentions the retired
# conflict-patch folder. A conflict is answered during the run, so a shipped
# instruction, script, rule or wiki page that still names the folder describes
# behavior that no longer exists. The allowed set is the history ledgers, the
# migration note that tells an adopter to delete a leftover folder, and test
# infrastructure, which builds the folder as a fixture to prove it is now an
# ordinary directory.

FOLDER_NAME='.gaia-merge'

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # The repository the helpers scan; a test points it at a scratch repository.
  SCAN_ROOT="$REPO_ROOT"
}

# Whether a tracked path is exempt from the check.
is_allowed_path() {
  case "$1" in
    CHANGELOG.md | wiki/log.md | wiki/meta/* | .gaia/migrations/2.0.0.md) return 0 ;;
    .gaia/tests/* | .gaia/scripts/tests/* | *.test.ts) return 0 ;;
  esac
  return 1
}

# Print every tracked path of SCAN_ROOT that the check covers, one per line.
scanned_paths() {
  local tracked_path
  while IFS= read -r -d '' tracked_path; do
    is_allowed_path "$tracked_path" || printf '%s\n' "$tracked_path"
  # gaia-lint-ignore whole-tree-mark-guard: every test that scans the real tracked tree through this listing
  # carries the per-test mark
  done < <(git -C "$SCAN_ROOT" ls-files -z)
}

# Print every covered path whose text names the folder.
offending_paths() {
  local scanned_path
  scanned_paths | while IFS= read -r scanned_path; do
    [ -f "$SCAN_ROOT/$scanned_path" ] || continue
    if grep -qIF -- "$FOLDER_NAME" "$SCAN_ROOT/$scanned_path"; then
      printf '%s\n' "$scanned_path"
    fi
  done
}

# Fail when the scan covers nothing, so a broken discovery cannot pass.
assert_scan_non_empty() {
  local scanned
  scanned="$(scanned_paths)"
  [ -n "$scanned" ] || return 1
}

# The whole check over SCAN_ROOT: a non-empty scan and no offender.
run_check() {
  assert_scan_non_empty || return 2
  local offenders
  offenders="$(offending_paths)"
  if [ -n "$offenders" ]; then
    printf '%s\n' "$offenders"
    return 1
  fi
  return 0
}

# A scratch git repository holding the given paths, each with the given text.
make_scratch_repo() {
  local repo="$1"
  shift
  mkdir -p "$repo"
  git -C "$repo" init -q
  local scratch_path
  for scratch_path in "$@"; do
    mkdir -p "$repo/$(dirname "$scratch_path")"
    printf 'see %s for details\n' "$FOLDER_NAME" >"$repo/$scratch_path"
    git -C "$repo" add -- "$scratch_path"
  done
}

# bats test_tags=whole-tree
@test "the scan covers the update skill, so discovery is not vacuous" {
  run scanned_paths
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -qxF '.claude/skills/update-gaia/SKILL.md' <<<"$output" || return 1
  grep -qxF '.claude/skills/update-gaia/references/conflict-flow.md' <<<"$output" || return 1
  true
}

# bats test_tags=whole-tree
@test "the scan leaves the allowed paths out" {
  run scanned_paths
  [ "$status" -eq 0 ]
  grep -qxF 'CHANGELOG.md' <<<"$output" && return 1
  grep -qxF '.gaia/migrations/2.0.0.md' <<<"$output" && return 1
  grep -q '^\.gaia/tests/' <<<"$output" && return 1
  true
}

# bats test_tags=whole-tree
@test "no tracked shipped file names the retired folder" {
  run run_check
  if [ "$status" -ne 0 ]; then
    printf 'offending paths:\n%s\n' "$output" >&2
    return 1
  fi
}

@test "a mention in a shipped path fails the check" {
  make_scratch_repo "$BATS_TEST_TMPDIR/shipped" \
    .claude/skills/example/SKILL.md README.md
  SCAN_ROOT="$BATS_TEST_TMPDIR/shipped"
  run run_check
  [ "$status" -eq 1 ]
  grep -qxF '.claude/skills/example/SKILL.md' <<<"$output" || return 1
  grep -qxF 'README.md' <<<"$output" || return 1
  true
}

@test "a mention only in allowed paths passes the check" {
  make_scratch_repo "$BATS_TEST_TMPDIR/allowed" \
    CHANGELOG.md wiki/log.md wiki/meta/report.md .gaia/migrations/2.0.0.md \
    .gaia/tests/lib/example.bats .gaia/scripts/tests/example.bats \
    .gaia/cli/src/example.test.ts
  printf 'ordinary\n' >"$BATS_TEST_TMPDIR/allowed/ordinary.txt"
  git -C "$BATS_TEST_TMPDIR/allowed" add -- ordinary.txt
  SCAN_ROOT="$BATS_TEST_TMPDIR/allowed"
  run run_check
  [ "$status" -eq 0 ]
}

@test "an empty scan fails the non-empty assertion" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  git -C "$BATS_TEST_TMPDIR/empty" init -q
  SCAN_ROOT="$BATS_TEST_TMPDIR/empty"
  run assert_scan_non_empty
  [ "$status" -ne 0 ]
  run run_check
  [ "$status" -eq 2 ]
}

@test "a repository holding only allowed paths fails the non-empty assertion" {
  make_scratch_repo "$BATS_TEST_TMPDIR/only-allowed" CHANGELOG.md wiki/log.md
  SCAN_ROOT="$BATS_TEST_TMPDIR/only-allowed"
  run run_check
  [ "$status" -eq 2 ]
}
