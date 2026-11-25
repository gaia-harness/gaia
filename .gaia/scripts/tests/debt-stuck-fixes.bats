#!/usr/bin/env bats
#
# Suite for .gaia/scripts/debt-stuck-fixes.sh, the stopped-debt-fix verdict.
# Each arm of the rule is driven on its own through the script's test seams,
# then every unreadable input is shown to print nothing and exit 3.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   bash .gaia/scripts/bats5.sh .gaia/scripts/tests/debt-stuck-fixes.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/debt-stuck-fixes.sh"
  printf '[{"number":11},{"number":12}]' >"$BATS_TEST_TMPDIR/claims.json"
  printf '[]' >"$BATS_TEST_TMPDIR/prs.json"
  : >"$BATS_TEST_TMPDIR/branches"
}

verdict() {
  run --separate-stderr bash "$SCRIPT" --claims-json "$BATS_TEST_TMPDIR/claims.json" \
    --prs-json "$BATS_TEST_TMPDIR/prs.json" --branches "$BATS_TEST_TMPDIR/branches" "$@"
}

@test "a claimed issue's debt branch with no pull request is reported with its branch" {
  printf 'main\ndebt/11-some-fix\n' >"$BATS_TEST_TMPDIR/branches"
  verdict
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '11\tdebt/11-some-fix')" ]
}

@test "the worktree spelling of the branch counts" {
  printf 'worktree-debt+11-some-fix\n' >"$BATS_TEST_TMPDIR/branches"
  verdict
  [ "$output" = "$(printf '11\tworktree-debt+11-some-fix')" ]
}

@test "a batch branch is one line carrying its lowest claimed member, or the member --issue names" {
  printf 'debt/10-11-12-batch\n' >"$BATS_TEST_TMPDIR/branches"
  verdict
  [ "$output" = "$(printf '11\tdebt/10-11-12-batch')" ]
  verdict --issue 12
  [ "$output" = "$(printf '12\tdebt/10-11-12-batch')" ]
}

@test "no line when the issue is unclaimed, the branch has an open pull request, or --issue names another member" {
  printf 'debt/13-unclaimed\n' >"$BATS_TEST_TMPDIR/branches"
  verdict
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'debt/11-some-fix\n' >"$BATS_TEST_TMPDIR/branches"
  printf '[{"headRefName":"debt/11-some-fix"}]' >"$BATS_TEST_TMPDIR/prs.json"
  verdict
  [ -z "$output" ]
  printf '[]' >"$BATS_TEST_TMPDIR/prs.json"
  verdict --issue 12
  [ -z "$output" ]
}

@test "a branch that is not a debt branch names no issue" {
  printf 'feat/11-not-debt\nmain\n' >"$BATS_TEST_TMPDIR/branches"
  verdict
  [ -z "$output" ]
}

@test "an unreadable input prints nothing and exits 3" {
  printf 'debt/11-some-fix\n' >"$BATS_TEST_TMPDIR/branches"
  printf 'not json' >"$BATS_TEST_TMPDIR/claims.json"
  verdict
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  printf '[{"number":11}]' >"$BATS_TEST_TMPDIR/claims.json"
  printf '{}' >"$BATS_TEST_TMPDIR/prs.json"
  verdict
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" --claims-json "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 3 ]
}

@test "a usage error exits 2" {
  run --separate-stderr bash "$SCRIPT" --issue abc
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}
