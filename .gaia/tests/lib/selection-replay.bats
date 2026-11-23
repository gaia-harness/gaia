#!/usr/bin/env bats

# Fixture suite for .gaia/tests/selection-replay.sh, the replay that re-runs the
# change-scoped selection over historical pull-request heads and reports whether
# each recorded failing test would still run. Every case builds on a fixture git
# repository holding copies of the sharder, the change classifier, the change
# selector and the mark-pattern library at their real relative paths, plus a
# fixture workflow carrying the filter block and a few tiny suites. The sharder
# derives its repository root from its own location, so the copy inside the
# fixture runs the fixture's own classifier and selector, and the real tree is
# never read.
#
# Each fixture commit touches exactly one path; a case pairs a commit with its
# parent. Cases that need a different suite shape rewrite one fixture suite in
# that test's own copy of the repository.
#
# Assertion style per .claude/rules/bats-assertions.md: POSIX [ ] and grep only.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

# write_suite <path> <file-tag-line|-> <test-tag-line|-> <test-name>...
# Writes a suite whose first test carries the given test tag line. The mark lines
# arrive assembled, so this file never holds one at column 0.
write_suite() {
  local path="$1" file_tag="$2" test_tag="$3" name first=1
  shift 3
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/usr/bin/env bats\n'
    if [ "$file_tag" != - ]; then printf '%s\n' "$file_tag"; fi
    printf '\n'
    for name in "$@"; do
      if [ "$first" -eq 1 ] && [ "$test_tag" != - ]; then printf '%s\n' "$test_tag"; fi
      first=0
      printf '@test "%s" {\n  true\n}\n\n' "$name"
    done
  } >"$path"
}

# commit_path <repo> <path>: appends a line to the path, records it in one
# fixture commit and prints the commit's SHA.
commit_path() {
  local repo="$1" path="$2"
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$RANDOM$RANDOM" >>"$repo/$path"
  git -C "$repo" add -- "$path"
  git -C "$repo" commit -q -m "touch $path"
  git -C "$repo" rev-parse HEAD
}

setup_file() {
  local seed="$BATS_FILE_TMPDIR/seed" lib="$BATS_FILE_TMPDIR/seed/.gaia/tests/lib"
  local whole_file whole_test dependency_file
  whole_file="$(printf '# bats file_tags=%s' whole-tree)"
  whole_test="$(printf '# bats test_tags=%s' whole-tree)"
  dependency_file="$(printf '# bats file_tags=%s' installed-dependencies)"
  mkdir -p "$seed/.gaia/tests/helpers" "$seed/.gaia/scripts" "$seed/.github/workflows"
  cp "$REAL_ROOT/.gaia/tests/bats-shards.sh" "$REAL_ROOT/.gaia/tests/bats-change-scope.sh" "$seed/.gaia/tests/"
  cp "$REAL_ROOT/.gaia/scripts/bats-suites-for-change.sh" "$REAL_ROOT/.gaia/scripts/bats-selector-reach-lib.sh" "$REAL_ROOT/.gaia/scripts/bats-selector-helper-lib.sh" "$seed/.gaia/scripts/"
  cp "$REAL_ROOT/.gaia/tests/helpers/verify-harness-bats-lib.sh" "$seed/.gaia/tests/helpers/"
  {
    printf 'name: fixture\njobs:\n  shards:\n    runs-on: ubuntu-latest\n    steps:\n'
    printf '      - uses: dorny/paths-filter@0000000000000000000000000000000000000000\n'
    printf '        id: filter\n        with:\n          filters: |\n'
    printf '            code:\n              - ".gaia/tests/bats-shards.sh"\n'
    printf '            scoped:\n              - "docs/**"\n'
    printf '            sandbox:\n              - "sandbox-input/**"\n'
    printf '            commitlint:\n              - "commitlint.config.txt"\n'
  } >"$seed/.github/workflows/audit-ci-tests.yml"
  write_suite "$lib/selected.bats" - - "reads the thing"
  printf '# names data/thing.conf\n' >>"$lib/selected.bats"
  write_suite "$lib/marked.bats" - "$whole_test" "marked test" "unmarked test"
  write_suite "$lib/plain.bats" - - "plain test"
  write_suite "$lib/filemarked.bats" "$whole_file" - "file marked test"
  write_suite "$lib/dependency.bats" "$dependency_file" - "dependency test"
  write_suite "$lib/dependency-plain.bats" - - "dependency plain test"
  write_suite "$seed/.gaia/tests/concurrency/meter.bats" - - "meter test"
  write_suite "$seed/.gaia/tests/commitlint/lint.bats" - - "lint test"
  mkdir -p "$seed/data"
  printf 'x\n' >"$seed/data/thing.conf"
  git -C "$seed" init -q -b main
  git -C "$seed" config user.email fixture@example.invalid
  git -C "$seed" config user.name fixture
  git -C "$seed" config commit.gpgsign false
  git -C "$seed" add -A
  git -C "$seed" commit -q -m base
  {
    printf 'BASE=%s\n' "$(git -C "$seed" rev-parse HEAD)"
    printf 'SELECTED=%s\n' "$(commit_path "$seed" data/thing.conf)"
    printf 'UNRELATED=%s\n' "$(commit_path "$seed" misc/unrelated.txt)"
    printf 'LOCKFILE=%s\n' "$(commit_path "$seed" pnpm-lock.yaml)"
    printf 'HELPER=%s\n' "$(commit_path "$seed" .gaia/tests/helpers/note.txt)"
    printf 'SCOPED=%s\n' "$(commit_path "$seed" docs/scoped-note.md)"
    printf 'NOWHERE=%s\n' "$(commit_path "$seed" elsewhere/nowhere.txt)"
    printf 'COMMITLINT=%s\n' "$(commit_path "$seed" commitlint.config.txt)"
  } >"$BATS_FILE_TMPDIR/shas"
}

setup() {
  cp -R "$BATS_FILE_TMPDIR/seed" "$BATS_TEST_TMPDIR/repo"
  # shellcheck disable=SC1091
  . "$BATS_FILE_TMPDIR/shas"
  SCRIPT="$REAL_ROOT/.gaia/tests/selection-replay.sh"
  CASES="$BATS_TEST_TMPDIR/cases.json"
  RESULTS="$BATS_TEST_TMPDIR/results.json"
}

# parent_of <sha>: the fixture commit before it.
parent_of() {
  git -C "$BATS_TEST_TMPDIR/repo" rev-parse "$1^"
}

# write_case <head> <suite> <test> [<extra-json-object>]: a one-case input file.
write_case() {
  local head="$1" suite="$2" test_name="$3" extra="${4:-}" merge_base
  if [ -z "$extra" ]; then extra='{}'; fi
  merge_base="$(parent_of "$head")"
  jq -n --arg head "$head" --arg merge_base "$merge_base" --arg suite "$suite" \
    --arg test "$test_name" --argjson extra "$extra" \
    '[{run_id: 1, pr: 2, head: $head, merge_base: $merge_base, leg: "lib", suite: $suite, test: $test} + $extra]' >"$CASES"
}

verdict_of() {
  jq -r '.[0].verdict' "$RESULTS"
}

@test "replay verdict per change kind and suite kind" {
  local label head_name suite test_name extra expected_status expected_verdict stderr_needle head
  # One fixture copy serves every case: each case writes its own input file,
  # and the one case that rewrites a fixture suite runs last.
  while IFS='|' read -r label head_name suite test_name extra expected_status expected_verdict stderr_needle; do
    [ -n "$label" ] || continue
    if [ "$label" = mark-removed ]; then
      grep -v 'test_tags' "$BATS_TEST_TMPDIR/repo/.gaia/tests/lib/marked.bats" >"$BATS_TEST_TMPDIR/marked.tmp"
      mv "$BATS_TEST_TMPDIR/marked.tmp" "$BATS_TEST_TMPDIR/repo/.gaia/tests/lib/marked.bats"
    fi
    head="${!head_name}"
    rm -f "$RESULTS"
    write_case "$head" "$suite" "$test_name" "$extra"
    run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
    [ "$status" -eq "$expected_status" ] || { echo "case $label: status $status, expected $expected_status"; return 1; }
    [ "$(verdict_of)" = "$expected_verdict" ] || { echo "case $label: verdict $(verdict_of), expected $expected_verdict"; return 1; }
    if [ -n "$stderr_needle" ]; then
      printf '%s\n' "$output" | grep -qF -- "$stderr_needle" || { echo "case $label: stderr does not name $stderr_needle"; return 1; }
    fi
  done <<'CASES'
selected|SELECTED|.gaia/tests/lib/selected.bats|reads the thing||0|selected-full|
whole-tree-test-mark|UNRELATED|.gaia/tests/lib/marked.bats|marked test||0|whole-tree-marked|
unmarked-unrelated|UNRELATED|.gaia/tests/lib/marked.bats|unmarked test||1|miss|unmarked test
lockfile-dependency|LOCKFILE|.gaia/tests/lib/dependency.bats|dependency test||0|dependency-full|
lockfile-no-dependency-mark|LOCKFILE|.gaia/tests/lib/dependency-plain.bats|dependency plain test||1|miss|
harness-only|HELPER|.gaia/tests/lib/plain.bats|plain test||0|harness-full|
concurrency-scoped|SCOPED|.gaia/tests/concurrency/meter.bats|meter test||0|leg-armed|
concurrency-no-filter|NOWHERE|.gaia/tests/concurrency/meter.bats|meter test||1|miss|
commitlint-filter|COMMITLINT|.gaia/tests/commitlint/lint.bats|lint test||0|leg-armed|
commitlint-scoped-only|SCOPED|.gaia/tests/commitlint/lint.bats|lint test||1|miss|
gone-with-marked-successor|UNRELATED|.gaia/tests/lib/marked.bats|renamed away|{"successor_suite": ".gaia/tests/lib/marked.bats", "successor_test": "marked test"}|0|whole-tree-marked|
gone-without-successor|UNRELATED|.gaia/tests/lib/marked.bats|renamed away||1|test-gone-today|
suite-successor-file-marked|UNRELATED|.gaia/tests/lib/plain.bats|gone|{"successor_suite": ".gaia/tests/lib/filemarked.bats", "successor_test": null}|0|whole-tree-marked|
suite-successor-unmarked|UNRELATED|.gaia/tests/lib/marked.bats|gone|{"successor_suite": ".gaia/tests/lib/plain.bats", "successor_test": null}|1|miss|
suite-successor-single-test-mark|UNRELATED|.gaia/tests/lib/plain.bats|gone|{"successor_suite": ".gaia/tests/lib/marked.bats", "successor_test": null}|1|miss|
mark-removed|UNRELATED|.gaia/tests/lib/marked.bats|marked test||1|miss|marked test
CASES
}

@test "malformed input exits 2 naming the fault" {
  local case_name needle grep_flags
  for case_name in absent-commit merge-base-equals-head malformed-json no-filter-block; do
    case "$case_name" in
      absent-commit)
        needle="0123456789012345678901234567890123456789"
        grep_flags=-qF
        write_case "$UNRELATED" .gaia/tests/lib/marked.bats "marked test"
        jq '.[0].head = "0123456789012345678901234567890123456789"' "$CASES" >"$CASES.tmp"
        mv "$CASES.tmp" "$CASES" ;;
      merge-base-equals-head)
        needle="merge_base"
        grep_flags=-qF
        write_case "$UNRELATED" .gaia/tests/lib/marked.bats "marked test"
        jq '.[0].merge_base = .[0].head' "$CASES" >"$CASES.tmp"
        mv "$CASES.tmp" "$CASES" ;;
      malformed-json)
        needle="json"
        grep_flags=-qi
        printf '[{"run_id": 1,\n' >"$CASES" ;;
      no-filter-block)
        needle="filter"
        grep_flags=-qi
        printf 'name: fixture\njobs:\n  shards:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' \
          >"$BATS_TEST_TMPDIR/repo/.github/workflows/audit-ci-tests.yml"
        write_case "$UNRELATED" .gaia/tests/lib/marked.bats "marked test" ;;
    esac
    run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
    [ "$status" -eq 2 ] || { echo "case $case_name: status $status"; return 1; }
    printf '%s\n' "$output" | grep "$grep_flags" -- "$needle" || { echo "case $case_name: output does not name $needle"; return 1; }
  done
}

@test "results are one entry per case in input order with the six fields" {
  local merge_base_one merge_base_two
  merge_base_one="$(parent_of "$SELECTED")"
  merge_base_two="$(parent_of "$UNRELATED")"
  jq -n --arg h1 "$SELECTED" --arg b1 "$merge_base_one" --arg h2 "$UNRELATED" --arg b2 "$merge_base_two" '[
    {run_id: 11, pr: 21, head: $h2, merge_base: $b2, leg: "lib", suite: ".gaia/tests/lib/marked.bats", test: "marked test"},
    {run_id: 12, pr: 22, head: $h1, merge_base: $b1, leg: "lib", suite: ".gaia/tests/lib/selected.bats", test: "reads the thing"}
  ]' >"$CASES"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' "$RESULTS")" -eq 2 ]
  [ "$(jq -r '[.[].run_id] | map(tostring) | join(",")' "$RESULTS")" = "11,12" ]
  [ "$(jq -r '[.[].verdict] | join(",")' "$RESULTS")" = "whole-tree-marked,selected-full" ]
  [ "$(jq -r '.[0] | keys | join(",")' "$RESULTS")" = "head,pr,run_id,suite,test,verdict" ]
}
