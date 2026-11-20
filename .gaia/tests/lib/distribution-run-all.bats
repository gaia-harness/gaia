#!/usr/bin/env bats
# The distribution runner's selection (.gaia/tests/distribution/run-all.sh): the
# skip marker, and the change-scoped mode a pull request runs, where a scenario
# that declares paths runs only when one of them changed. Each case runs a copy
# of the runner beside fixture scenarios that record whether they ran.
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
  run env DISTRIBUTION_JOBS=1 bash "$DISTRIBUTION/run-all.sh" "$@"
}

# changed <path>...: writes the changed-path list the pull-request lane hands
# the runner, one repo-relative path per line, and prints the file's path.
changed() {
  local list="$BATS_TEST_TMPDIR/changed-paths.txt"
  printf '%s\n' "$@" > "$list"
  printf '%s\n' "$list"
}

# reset_scenarios: removes every fixture scenario and recorded run, so each row
# of a case table starts from an empty runner directory.
reset_scenarios() {
  rm -f "$DISTRIBUTION"/[0-9]*.sh "$RAN"/*
}

@test "the skip marker keeps a scenario from running and failing the run, wins over exclusive and over a matching paths declaration, and an unmarked failing scenario runs and fails" {
  scenario 01-runs.sh 0
  scenario 02-skipped.sh 1 '# distribution-runner: skip'
  run_all
  [ "$status" -eq 0 ] || { echo "skipped: status $status"; return 1; }
  [ -f "$RAN/01-runs.sh" ] || { echo "skipped: 01-runs.sh did not run"; return 1; }
  [ -e "$RAN/02-skipped.sh" ] && { echo "skipped: 02-skipped.sh ran"; return 1; }
  printf '%s\n' "$output" | grep -qx 'SKIP  02-skipped.sh' || { echo "skipped: no SKIP line"; return 1; }
  printf '%s\n' "$output" | grep -qx 'PASS  01-runs.sh' || { echo "skipped: no PASS line"; return 1; }
  printf '%s\n' "$output" | grep -q 'skipping 1$' || { echo "skipped: no skipping count"; return 1; }

  reset_scenarios
  scenario 01-runs.sh 0
  scenario 02-unmarked.sh 1
  run_all
  [ "$status" -eq 1 ] || { echo "unmarked: status $status"; return 1; }
  [ -f "$RAN/02-unmarked.sh" ] || { echo "unmarked: 02-unmarked.sh did not run"; return 1; }
  printf '%s\n' "$output" | grep -qx 'FAIL  02-unmarked.sh' || { echo "unmarked: no FAIL line"; return 1; }

  reset_scenarios
  scenario 01-runs.sh 0
  scenario 02-exclusive-skipped.sh 1 '# distribution-runner: exclusive' '# distribution-runner: skip'
  scenario 03-exclusive.sh 0 '# distribution-runner: exclusive'
  run_all
  [ "$status" -eq 0 ] || { echo "exclusive: status $status"; return 1; }
  [ -e "$RAN/02-exclusive-skipped.sh" ] && { echo "exclusive: skipped scenario ran"; return 1; }
  [ -f "$RAN/03-exclusive.sh" ] || { echo "exclusive: 03-exclusive.sh did not run"; return 1; }
  printf '%s\n' "$output" | grep -qx 'SKIP  02-exclusive-skipped.sh' || { echo "exclusive: no SKIP line"; return 1; }
  printf '%s\n' "$output" | grep -qx 'PASS  03-exclusive.sh' || { echo "exclusive: no PASS line"; return 1; }

  reset_scenarios
  scenario 01-slow.sh 1 '# distribution-runner: skip' '# distribution-runner: paths .gaia/cli/src/scaffold/**'
  scenario 02-fast.sh 0
  run_all --changed-paths "$(changed .gaia/cli/src/scaffold/route.ts)"
  [ "$status" -eq 0 ] || { echo "matching paths: status $status"; return 1; }
  [ -e "$RAN/01-slow.sh" ] && { echo "matching paths: skipped scenario ran"; return 1; }
  printf '%s\n' "$output" | grep -qx 'SKIP  01-slow.sh' || { echo "matching paths: no SKIP line"; return 1; }
}

@test "change-scoped selection runs a declared scenario when a matching glob, a second paths line, its own file or a shared harness input changed, skips it when none did, and a run with no list runs everything" {
  local shared

  scenario 01-fast.sh 0
  scenario 02-slow.sh 0 '# distribution-runner: paths .gaia/cli/src/scaffold/** apps/web/package.json'
  run_all --changed-paths "$(changed .gaia/cli/src/scaffold/route-data.ts)"
  [ "$status" -eq 0 ] || { echo "matching glob: status $status"; return 1; }
  [ -f "$RAN/01-fast.sh" ] || { echo "matching glob: 01-fast.sh did not run"; return 1; }
  [ -f "$RAN/02-slow.sh" ] || { echo "matching glob: 02-slow.sh did not run"; return 1; }
  printf '%s\n' "$output" | grep -qx 'PASS  02-slow.sh' || { echo "matching glob: no PASS line"; return 1; }

  reset_scenarios
  scenario 01-fast.sh 0
  scenario 02-slow.sh 1 '# distribution-runner: paths .gaia/cli/src/scaffold/**'
  run_all --changed-paths "$(changed .gaia/cli/src/release/bump.ts)"
  [ "$status" -eq 0 ] || { echo "no declared path: status $status"; return 1; }
  [ -f "$RAN/01-fast.sh" ] || { echo "no declared path: 01-fast.sh did not run"; return 1; }
  [ -e "$RAN/02-slow.sh" ] && { echo "no declared path: 02-slow.sh ran"; return 1; }
  printf '%s\n' "$output" | grep -qx 'SKIP  02-slow.sh (no declared path changed)' || { echo "no declared path: no SKIP line"; return 1; }
  printf '%s\n' "$output" | grep -q 'skipping 1$' || { echo "no declared path: no skipping count"; return 1; }

  reset_scenarios
  scenario 01-slow.sh 0 '# distribution-runner: paths .gaia/cli/src/init/**' '# distribution-runner: paths apps/web/.storybook/**'
  run_all --changed-paths "$(changed apps/web/.storybook/preview.ts)"
  [ "$status" -eq 0 ] || { echo "second paths line: status $status"; return 1; }
  [ -f "$RAN/01-slow.sh" ] || { echo "second paths line: 01-slow.sh did not run"; return 1; }

  reset_scenarios
  scenario 01-slow.sh 0 '# distribution-runner: paths .gaia/cli/src/scaffold/**'
  run_all --changed-paths "$(changed .gaia/tests/distribution/01-slow.sh)"
  [ "$status" -eq 0 ] || { echo "own file: status $status"; return 1; }
  [ -f "$RAN/01-slow.sh" ] || { echo "own file: 01-slow.sh did not run"; return 1; }

  for shared in .gaia/tests/distribution/run-all.sh .gaia/tests/distribution/lib/lib.sh \
    .github/workflows/distribution-harness.yml .github/actions/gaia-setup-node/action.yml; do
    reset_scenarios
    scenario 01-slow.sh 0 '# distribution-runner: paths .gaia/cli/src/scaffold/**'
    run_all --changed-paths "$(changed "$shared")"
    [ "$status" -eq 0 ] || { echo "$shared: status $status"; return 1; }
    [ -f "$RAN/01-slow.sh" ] || { echo "$shared did not run the declared scenario"; return 1; }
  done

  reset_scenarios
  scenario 01-fast.sh 0
  scenario 02-slow.sh 1 '# distribution-runner: paths .gaia/cli/src/scaffold/**'
  run_all
  [ "$status" -eq 1 ] || { echo "no list: status $status"; return 1; }
  [ -f "$RAN/02-slow.sh" ] || { echo "no list: 02-slow.sh did not run"; return 1; }
  printf '%s\n' "$output" | grep -qx 'FAIL  02-slow.sh' || { echo "no list: no FAIL line"; return 1; }
}

@test "change-scoped: an unreadable changed-path list or an unknown argument exits 2 and runs nothing" {
  scenario 01-fast.sh 0
  run_all --changed-paths "$BATS_TEST_TMPDIR/absent.txt"
  [ "$status" -eq 2 ]
  run_all --changed-paths
  [ "$status" -eq 2 ]
  run_all --bogus
  [ "$status" -eq 2 ]
  [ -e "$RAN/01-fast.sh" ] && return 1
  true
}

# bats test_tags=whole-tree
@test "only the slow scenarios declare paths, and none is skip-marked" {
  local file name declared=()
  for file in "$REPO_ROOT"/.gaia/tests/distribution/[0-9]*.sh; do
    name="$(basename "$file")"
    grep -qxF '# distribution-runner: skip' "$file" && { echo "$name is skip-marked" >&2; return 1; }
    grep -q '^# distribution-runner: paths ' "$file" && declared+=("$name")
  done
  [ "${declared[*]}" = "09-data-layer-query-on.sh 10-data-layer-query-off.sh 17-csf4-scaffolds.sh 18-fresh-apps-web.sh 21-workspace-gate.sh" ] \
    || { echo "declared: ${declared[*]}" >&2; return 1; }
}

# duplicate_scenario_numbers <directory>: prints each number two or more
# scenarios share. Read as a base-10 integer, so `1-` and `01-` collide too.
duplicate_scenario_numbers() {
  local file name
  for file in "$1"/[0-9]*.sh; do
    [ -e "$file" ] || continue
    name="$(basename "$file")"
    printf '%d\n' "$((10#${name%%[!0-9]*}))"
  done | sort -n | uniq -d
}

# A bare number ("scenario 12") is how comments, workflows and the wiki name a
# scenario, so two scenarios sharing one make every such reference ambiguous.
# Gaps are fine: deleting a scenario leaves one, and nothing reads the count.
# bats test_tags=whole-tree
@test "no two live scenarios share a number" {
  local scenarios=("$REPO_ROOT"/.gaia/tests/distribution/[0-9]*.sh) duplicates
  [ -e "${scenarios[0]}" ] || { echo "no scenarios found" >&2; return 1; }
  duplicates="$(duplicate_scenario_numbers "$REPO_ROOT/.gaia/tests/distribution")"
  [ -z "$duplicates" ] || { echo "shared numbers: $duplicates" >&2; return 1; }
}

# A pull request reaches run-all.sh only when the workflow's `code:` filter
# matched, so a declared glob that filter does not cover could never select its
# scenario on a pull request. Each declared glob must match, as a string, one
# of the filter's entries read as a bash pattern.
declared_globs() {
  local file line
  for file in "$1"/[0-9]*.sh; do
    while IFS= read -r line; do
      # Unquoted on purpose: word-splits the line into its globs. noglob keeps
      # each glob literal.
      set -f
      # shellcheck disable=SC2086
      printf '%s\n' ${line#'# distribution-runner: paths '}
      set +f
    done < <(grep '^# distribution-runner: paths ' "$file")
  done
}

workflow_code_filter() {
  awk '
    /^ *code: *$/ { in_filter = 1; next }
    in_filter && /^ *- / { line = $0; sub(/^ *- */, "", line); gsub(/\047/, "", line); print line; next }
    in_filter && /^ *#/ { next }
    in_filter { exit }
  ' "$1"
}

uncovered_globs() {
  local glob entry covered
  while IFS= read -r glob; do
    covered=0
    while IFS= read -r entry; do
      # shellcheck disable=SC2053 # the filter entry is the pattern
      [[ "$glob" == $entry ]] && { covered=1; break; }
    done <<<"$2"
    [ "$covered" -eq 1 ] || printf '%s\n' "$glob"
  done <<<"$1"
}

# bats test_tags=whole-tree
@test "every declared glob is covered by the harness workflow's code filter" {
  local globs entries uncovered
  globs="$(declared_globs "$REPO_ROOT/.gaia/tests/distribution")"
  entries="$(workflow_code_filter "$REPO_ROOT/.github/workflows/distribution-harness.yml")"
  [ -n "$globs" ]
  [ -n "$entries" ]
  uncovered="$(uncovered_globs "$globs" "$entries")"
  [ -z "$uncovered" ] || { printf 'not covered by the code filter: %s\n' "$uncovered" >&2; return 1; }
}

@test "the harness workflow runs the full harness on every push to main and change-scopes only pull requests" {
  local workflow="$REPO_ROOT/.github/workflows/distribution-harness.yml"
  awk '/^on:/ { on = 1; next } on && /^[a-z]/ { exit } on' "$workflow" | grep -qE '^  push:'
  grep -qE '^ *if \[ "\$EVENT_NAME" = pull_request \]; then$' "$workflow"
  grep -qE '^ *bash \.gaia/tests/distribution/run-all\.sh --changed-paths "\$changed_paths"$' "$workflow"
  grep -qE '^ *bash \.gaia/tests/distribution/run-all\.sh$' "$workflow"
}

@test "a main-push harness failure feeds the red-main reporter under its own check name" {
  local workflow="$REPO_ROOT/.github/workflows/distribution-harness.yml"
  grep -qE "^ *if: always\(\) && github.event_name == 'push' && github.ref == 'refs/heads/main'$" "$workflow"
  grep -qE '^ *SHARDS_RESULT: \$\{\{ needs\.distribution-harness\.result \}\}$' "$workflow"
  grep -qE '^ *CHECK_NAME: ' "$workflow"
  grep -qE '^ *run: bash \.gaia/tests/report-main-status\.sh$' "$workflow"
}
