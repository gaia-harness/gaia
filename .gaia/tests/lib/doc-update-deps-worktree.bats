#!/usr/bin/env bats
#
# Doc-pin: /update-deps runs a default-branch, interactive run in its own
# worktree.
#
# Static checks over `.claude/skills/update-deps/SKILL.md` and its references
# `worktree.md` (the one worktree-creation instruction) and `publish.md`:
# the creation condition, mode 1's publish and provisioning wait, the
# post-merge cache bust, and the worktree path of a non-default branch.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SKILL_DIR="${REPO_ROOT}/.claude/skills/update-deps"
  SKILL="${SKILL_DIR}/SKILL.md"
  WORKTREE="${SKILL_DIR}/references/worktree.md"
  PUBLISH="${SKILL_DIR}/references/publish.md"
  local file
  for file in "$SKILL" "$WORKTREE" "$PUBLISH"; do
    [ -f "$file" ] || {
      echo "an audited page is absent: ${file}" >&2
      return 1
    }
  done
}

# line_of <file> <fixed-string>: the first line number holding the string, or
# nothing when it is absent.
line_of() {
  NEEDLE="$2" awk 'index($0, ENVIRON["NEEDLE"]) { print NR; exit }' "$1"
}

# must_contain <file> <fixed-string> <message>: fail with the message when the
# string is absent.
must_contain() {
  grep -qF -- "$2" "$1" || {
    echo "$3" >&2
    return 1
  }
}

# must_precede <file> <earlier> <later> <message>: both strings are present and
# the first one's first line comes before the second one's.
must_precede() {
  local earlier later
  earlier="$(line_of "$1" "$2")"
  later="$(line_of "$1" "$3")"
  { [ -n "$earlier" ] && [ -n "$later" ] && [ "$earlier" -lt "$later" ]; } || {
    echo "$4" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# 1. Creation is conditioned on the flag
# ---------------------------------------------------------------------------

CREATION_CONDITION='Run it only when `SHOULD_CREATE_WORKTREE=true`'

check_creation_condition() {
  must_contain "$WORKTREE" "$CREATION_CONDITION" "the creation subsection is not conditioned on SHOULD_CREATE_WORKTREE=true"
}

# bats test_tags=whole-tree
@test "worktree creation is conditioned on the flag" {
  check_creation_condition
}

# ---------------------------------------------------------------------------
# Mode 1 publishes as a worktree run
# ---------------------------------------------------------------------------

IN_PLACE_PUBLISH='a worktree run in place because the session started inside its own update worktree (mode 1)'

check_mode_one_publish() {
  must_contain "$PUBLISH" "$IN_PLACE_PUBLISH" "publish does not take mode 1 as a worktree run" || return 1
  must_precede "$PUBLISH" 'gh pr list --head <branch-name> --state open' '`gh pr create --draft`' "the open-PR check does not come before gh pr create"
}

# bats test_tags=whole-tree
@test "mode 1 publishes as a worktree run and checks for an open PR before creating one" {
  check_mode_one_publish
}

# ---------------------------------------------------------------------------
# The post-merge cache bust
# ---------------------------------------------------------------------------

POST_MERGE_BUST_CALL='bash <main checkout path>/.gaia/scripts/update-check-bust.sh --cache <main checkout path>/.gaia/local/cache/shared/update-check.json --mode deps'

# The decision-time bust lands before the bump reaches the main checkout, so
# any writer that marks the cache stale before the merge lets a refresh
# recount against the pre-merge tree. Only a bust after MERGED, once cleanup
# has pulled the main checkout, leaves the cache true.
check_post_merge_bust() {
  local arm
  arm="$(grep -F -- '**`MERGED`**' "$PUBLISH")"
  grep -qF -- "$POST_MERGE_BUST_CALL" <<<"$arm" || {
    echo "the MERGED arm does not bust the cache after cleanup" >&2
    return 1
  }
}

@test "publish's MERGED arm busts the cache again after cleanup" {
  check_post_merge_bust
}

# ---------------------------------------------------------------------------
# A non-default branch takes the worktree path
# ---------------------------------------------------------------------------

MAIN_CHECKOUT_MODE='2. **In the main checkout, on `main`, `master` or any other branch.**'
UNDECLARED_RECONCILE='and so does a package neither of the worktree'"'"'s `package.json` files declares'

check_feature_branch_worktree() {
  must_contain "$SKILL" "$MAIN_CHECKOUT_MODE" "the worktree mode does not cover a non-default branch" || return 1
  must_contain "$WORKTREE" "$UNDECLARED_RECONCILE" "the reconcile does not drop a package the default branch does not declare" || return 1
  grep -qF -- 'push only' "$SKILL" && {
    echo "SKILL.md still states a push-only mode" >&2
    return 1
  }
  grep -qx -- '   git push' "$PUBLISH" && {
    echo "publish still has a push-only arm" >&2
    return 1
  }
  true
}

# bats test_tags=whole-tree
@test "a run on a non-default branch takes the worktree path, and no run pushes without a PR" {
  check_feature_branch_worktree
}

# ---------------------------------------------------------------------------
# Mode 1 waits for provisioning before discovery
# ---------------------------------------------------------------------------

DISCOVERY_CALL='update-deps run --emit-updates'

PROVISION_CALL='bash .gaia/scripts/provision-wait.sh --tree <worktree path>'

check_mode_one_wait() {
  must_precede "$SKILL" "$PROVISION_CALL" "$DISCOVERY_CALL" "mode 1 has no provisioning wait before discovery"
}

# bats test_tags=whole-tree
@test "mode 1 waits for provisioning before discovery" {
  check_mode_one_wait
}
