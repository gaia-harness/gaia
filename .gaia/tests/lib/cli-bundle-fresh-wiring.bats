#!/usr/bin/env bats
#
# Pins the PR-time half of the CLI bundle-freshness gate: cli-tests.yml runs
# verify-cli-bundle-fresh.sh, so a pull request that edits .gaia/cli/src
# without rebuilding the committed bundles fails before merge rather than at
# the release tag.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/cli-tests.yml"
  FRESHNESS_STEP_ERE='^[[:space:]]+run: bash \.gaia/scripts/verify-cli-bundle-fresh\.sh'
}

# freshness_step_active <workflow>: rc 0 when an uncommented YAML run line
# invokes the freshness script.
freshness_step_active() {
  grep -qE -- "$FRESHNESS_STEP_ERE" "$1"
}

@test "the PR-time bundle-freshness step is wired into cli-tests" {
  freshness_step_active "$WORKFLOW"
}
