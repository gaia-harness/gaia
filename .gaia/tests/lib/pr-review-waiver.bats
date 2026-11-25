#!/usr/bin/env bats
#
# .claude/hooks/lib/pr-review-waiver.sh: a pull request is waived from the PR
# review record only when its title names a release AND its diff is release
# bookkeeping; neither alone waives, and every unreadable input fails closed.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/pr-review-waiver.bats < /dev/null
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$BATS_TEST_DIRNAME/../helpers/release-bookkeeping-fixture.sh"
  . "$REPO_ROOT/.claude/hooks/lib/pr-review-waiver.sh"
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX"
  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false
  release_bookkeeping_seed_base "$SANDBOX"
  BASE="$(git -C "$SANDBOX" rev-parse HEAD)"
  release_bookkeeping_install_predicate "$SANDBOX"
}

# bats test_tags=protected
@test "a release title waives only a change that is release bookkeeping" {
  local row

  release_bookkeeping_apply "$SANDBOX"
  head="$(git -C "$SANDBOX" rev-parse HEAD)"

  # Row: title and bookkeeping diff.
  pr_review_release_waived "$SANDBOX" "chore(release): v1.1.0" "$BASE" "$head" || { echo "row title and bookkeeping: not waived"; return 1; }

  # Rows: the title is not exactly a release title.
  for row in "chore(release): v1.1.0 extra" "chore(release): 1.1.0" "chore(release): v1.1" "fix: chore(release): v1.1.0" "chore: bump versions" ""; do
    pr_review_release_waived "$SANDBOX" "$row" "$BASE" "$head" && { echo "row title [$row]: waived"; return 1; }
  done

  # Rows: an empty argument fails closed.
  pr_review_release_waived "" "chore(release): v1.1.0" "$BASE" "$head" && { echo "row empty root: waived"; return 1; }
  pr_review_release_waived "$SANDBOX" "chore(release): v1.1.0" "" "$head" && { echo "row empty base: waived"; return 1; }
  pr_review_release_waived "$SANDBOX" "chore(release): v1.1.0" "$BASE" "" && { echo "row empty head: waived"; return 1; }
  true
}

# bats test_tags=protected
@test "the release title alone waives nothing when the change is more than bookkeeping" {
  release_bookkeeping_apply "$SANDBOX" extra
  head="$(git -C "$SANDBOX" rev-parse HEAD)"
  pr_review_release_waived "$SANDBOX" "chore(release): v1.1.0" "$BASE" "$head" && return 1
  true
}

@test "a missing predicate script fails closed" {
  release_bookkeeping_apply "$SANDBOX"
  head="$(git -C "$SANDBOX" rev-parse HEAD)"
  rm -f "$SANDBOX/.gaia/scripts/release-bookkeeping-check.sh"
  pr_review_release_waived "$SANDBOX" "chore(release): v1.1.0" "$BASE" "$head" && return 1
  true
}

@test "a branch that edits the predicate it is judged by is not waived" {
  git -C "$SANDBOX" add -f .gaia/scripts/release-bookkeeping-check.sh
  git -C "$SANDBOX" commit --quiet -m "track predicate"
  BASE="$(git -C "$SANDBOX" rev-parse HEAD)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/.gaia/scripts/release-bookkeeping-check.sh"
  git -C "$SANDBOX" commit --quiet -am "loosen predicate"
  release_bookkeeping_apply "$SANDBOX" extra
  head="$(git -C "$SANDBOX" rev-parse HEAD)"
  pr_review_release_waived "$SANDBOX" "chore(release): v1.1.0" "$BASE" "$head" && return 1
  true
}
