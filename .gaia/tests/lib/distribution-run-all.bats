#!/usr/bin/env bats
# The distribution runner's skip marker (.gaia/tests/distribution/run-all.sh):
# a scenario carrying it runs in neither phase, prints as SKIP, and never
# decides the exit status, while an unmarked scenario still runs. Each case runs
# a copy of the runner beside fixture scenarios that record whether they ran.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DISTRIBUTION="$BATS_TEST_TMPDIR/distribution"
  RAN="$BATS_TEST_TMPDIR/ran"
  mkdir -p "$DISTRIBUTION" "$RAN"
  cp "$REPO_ROOT/.gaia/tests/distribution/run-all.sh" "$DISTRIBUTION/run-all.sh"
}

# scenario <file> <exit status> [header line...]: a scenario that records its
# run under $RAN and exits with <exit status>.
scenario() {
  local file="$1" exit_status="$2" header
  shift 2
  {
    printf '#!/usr/bin/env bash\n# %s\n' "$file"
    for header in "$@"; do
      printf '%s\n' "$header"
    done
    printf 'touch %q\nexit %s\n' "$RAN/$file" "$exit_status"
  } > "$DISTRIBUTION/$file"
}

run_all() {
  run env DISTRIBUTION_JOBS=1 bash "$DISTRIBUTION/run-all.sh"
}

@test "a skip-marked scenario never runs, prints as SKIP, and its failure does not fail the run" {
  scenario 01-runs.sh 0
  scenario 02-skipped.sh 1 '# distribution-runner: skip'
  run_all
  [ "$status" -eq 0 ]
  [ -f "$RAN/01-runs.sh" ]
  [ -e "$RAN/02-skipped.sh" ] && return 1
  printf '%s\n' "$output" | grep -qx 'SKIP  02-skipped.sh'
  printf '%s\n' "$output" | grep -qx 'PASS  01-runs.sh'
  printf '%s\n' "$output" | grep -q 'skipping 1$'
}

@test "red twin: the same failing scenario without the marker runs and fails the run" {
  scenario 01-runs.sh 0
  scenario 02-unmarked.sh 1
  run_all
  [ "$status" -eq 1 ]
  [ -f "$RAN/02-unmarked.sh" ]
  printf '%s\n' "$output" | grep -qx 'FAIL  02-unmarked.sh'
}

@test "the skip marker wins over the exclusive marker" {
  scenario 01-runs.sh 0
  scenario 02-exclusive-skipped.sh 1 '# distribution-runner: exclusive' '# distribution-runner: skip'
  scenario 03-exclusive.sh 0 '# distribution-runner: exclusive'
  run_all
  [ "$status" -eq 0 ]
  [ -e "$RAN/02-exclusive-skipped.sh" ] && return 1
  [ -f "$RAN/03-exclusive.sh" ]
  printf '%s\n' "$output" | grep -qx 'SKIP  02-exclusive-skipped.sh'
  printf '%s\n' "$output" | grep -qx 'PASS  03-exclusive.sh'
}

@test "the CSF4 migration scenario is skipped by default and the scaffold scenario is not" {
  grep -qxF '# distribution-runner: skip' "$REPO_ROOT/.gaia/tests/distribution/25-csf4-migration.sh"
  grep -qxF '# distribution-runner: skip' "$REPO_ROOT/.gaia/tests/distribution/26-csf4-scaffolds.sh" && return 1
  true
}
