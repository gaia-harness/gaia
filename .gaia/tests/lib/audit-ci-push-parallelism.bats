#!/usr/bin/env bats
# The shards job in .github/workflows/audit-ci-tests.yml caps how many legs a
# push run to main runs at once, so a push run that runs every leg whole
# leaves concurrent-job slots free for pull requests, while a pull request
# keeps every leg parallel. The guard derives the leg count from the matrix
# rather than pinning it, so adding or removing a leg moves it with the matrix.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]], no `!`-negated non-final assertion.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

setup() {
  WORKFLOW="$BATS_TEST_DIRNAME/../../../.github/workflows/audit-ci-tests.yml"
  [ -f "$WORKFLOW" ]
}

# The shards job's strategy block, from `strategy:` to the job's `steps:`.
shards_strategy() {
  awk '
    /^  shards:/ { in_job = 1; next }
    in_job && /^  [a-z]/ { exit }
    in_job && /^    strategy:/ { in_strategy = 1 }
    in_strategy && /^    steps:/ { exit }
    in_strategy { print }
  ' "$1"
}

matrix_leg_count() {
  shards_strategy "$1" | sed -n 's/^[[:space:]]*shard:[[:space:]]*\[\(.*\)\][[:space:]]*$/\1/p' | tr ',' '\n' | grep -c '[a-z]'
}

# Prints "<push value> <pull request value>" from
# max-parallel: ${{ github.event_name == 'push' && <push> || <pull request> }}
max_parallel_values() {
  shards_strategy "$1" |
    sed -n "s/^[[:space:]]*max-parallel:[[:space:]]*\${{[[:space:]]*github\.event_name == 'push' && \([0-9][0-9]*\) || \([0-9][0-9]*\)[[:space:]]*}}[[:space:]]*$/\1 \2/p"
}

push_runs_are_capped() {
  local legs values push_value pull_request_value
  legs="$(matrix_leg_count "$1")"
  [ "$legs" -gt 1 ] || return 1
  values="$(max_parallel_values "$1")"
  [ -n "$values" ] || return 1
  read -r push_value pull_request_value <<<"$values"
  [ "$push_value" -ge 1 ] || return 1
  [ "$push_value" -lt "$pull_request_value" ] || return 1
  [ "$pull_request_value" -eq "$legs" ]
}

@test "a push run is capped below the leg count and a pull request runs every leg at once" {
  push_runs_are_capped "$WORKFLOW"
}

@test "the guard fails on a cap that also binds pull requests, a missing cap, or a stale leg count (the guard can fail)" {
  local scratch="$BATS_TEST_TMPDIR/audit-ci-tests.yml" legs
  legs="$(matrix_leg_count "$WORKFLOW")"
  sed "s/^\([[:space:]]*max-parallel:\).*/\1 6/" "$WORKFLOW" >"$scratch"
  cmp -s "$WORKFLOW" "$scratch" && return 1
  run push_runs_are_capped "$scratch"
  [ "$status" -ne 0 ] || return 1
  sed '/^[[:space:]]*max-parallel:/d' "$WORKFLOW" >"$scratch"
  run push_runs_are_capped "$scratch"
  [ "$status" -ne 0 ] || return 1
  sed "s/\(github\.event_name == 'push' && [0-9]* || \)[0-9]*/\1$((legs + 1))/" "$WORKFLOW" >"$scratch"
  cmp -s "$WORKFLOW" "$scratch" && return 1
  run push_runs_are_capped "$scratch"
  [ "$status" -ne 0 ]
}
