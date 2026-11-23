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
  # The repository the helpers scan.
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

# bats test_tags=whole-tree
@test "no tracked shipped file names the retired folder" {
  run run_check
  if [ "$status" -ne 0 ]; then
    printf 'offending paths:\n%s\n' "$output" >&2
    return 1
  fi
}
