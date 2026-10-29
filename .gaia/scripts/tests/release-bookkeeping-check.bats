#!/usr/bin/env bats
#
# Requires Bats >= 1.5.0 (the negative `run !` assertions below).
bats_require_minimum_version 1.5.0
#
# Tests for `.gaia/scripts/release-bookkeeping-check.sh`, the one predicate for
# "this change is release bookkeeping and nothing else" that the CI fast path,
# verify-harness branch mode and the audit scope share.
#
# Each test builds a throwaway repository holding the release bookkeeping files
# at 1.0.0 and a release commit that graduates it to 1.1.0 the way
# /gaia-release does, then perturbs one thing. ci mode reaches GitHub only
# through a PATH stub for `gh`, and its manifest check runs a stub
# `.gaia/cli/gaia-maintainer` committed into the fixture.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIRECTORY/../release-bookkeeping-check.sh"
  [ -x "$SCRIPT" ]
  FIXTURE="$BATS_TEST_TMPDIR/repository"
  build_base
}

fixture_git() {
  git -C "$FIXTURE" -c user.name=test -c user.email=test@example.test -c commit.gpgsign=false "$@"
}

write_file() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  printf '%s' "$2" > "$FIXTURE/$1"
}

package_json() {
  printf '{\n  "name": "%s",\n  "version": "%s",\n  "private": true\n}\n' "$1" "$2"
}

manifest_json() {
  printf '{\n  "files": {\n    "a.sh": "owned"\n  },\n  "generated": "%s",\n  "version": "%s"\n}\n' "$1" "$2"
}

state_json() {
  printf '{\n  "version": 1,\n  "last_evaluated_sha": "%s",\n  "last_evaluated_at": "%s",\n  "last_consolidated_sha": "aaaa"\n}\n' "$1" "$2"
}

scrubbed_log() {
  printf -- '---\ntype: meta\ntitle: Log\nstatus: active\ncreated: %s\nupdated: %s\ntags: [meta, log]\n---\n\n# Log\n\n## [v%s] %s | Released\n\nSee CHANGELOG.md for details.\n' "$2" "$2" "$1" "$2"
}

changelog() {
  # changelog <unreleased-compare-version> [<graduated-version>]
  printf '# Changelog\n\n## [Unreleased]\n\n'
  [ -z "${2:-}" ] || printf '## [%s] - 2026-10-29\n\n' "$2"
  printf '### Added\n\n- **Thing:** it works (#1)\n\n## [1.0.0] - 2026-10-01\n\n- First.\n\n'
  printf '[Unreleased]: https://github.com/example/repo/compare/v%s...HEAD\n' "$1"
  [ -z "${2:-}" ] || printf '[%s]: https://github.com/example/repo/releases/tag/v%s\n' "$2" "$2"
  printf '[1.0.0]: https://github.com/example/repo/releases/tag/v1.0.0\n'
}

build_base() {
  mkdir -p "$FIXTURE"
  git init -q -b main "$FIXTURE"
  write_file .gaia/VERSION $'1.0.0\n'
  write_file .gaia/manifest.json "$(manifest_json 2026-10-01T00:00:00.000Z 1.0.0)"
  write_file package.json "$(package_json gaia 1.0.0)"
  write_file frontend/package.json "$(package_json frontend 1.0.0)"
  write_file CHANGELOG.md "$(changelog 1.0.0)"
  write_file wiki/.state.json "$(state_json 1111 2026-10-28T00:00:00Z)"
  write_file wiki/log.md $'---\ntype: meta\n---\n\n# Log\n\n## [Unreleased]\n\n- 2026-10-28 abc WORTHY - a change\n'
  write_file a.sh $'echo hi\n'
  write_file .gaia/cli/gaia-maintainer $'#!/usr/bin/env node\nprocess.exit(process.env.MANIFEST_CHECK_FAILS ? 1 : 0);\n'
  fixture_git add -A
  fixture_git commit -qm base
  BASE_SHA="$(fixture_git rev-parse HEAD)"
}

# Applies the release edits to the working tree; a test perturbs them before
# commit_release.
apply_release() {
  write_file .gaia/VERSION $'1.1.0\n'
  write_file .gaia/manifest.json "$(manifest_json 2026-10-29T00:00:00.000Z 1.1.0)"
  write_file package.json "$(package_json gaia 1.1.0)"
  write_file frontend/package.json "$(package_json frontend 1.1.0)"
  write_file CHANGELOG.md "$(changelog 1.1.0 1.1.0)"
  write_file wiki/.state.json "$(state_json 2222 2026-10-29T00:00:00Z)"
  write_file wiki/log.md "$(scrubbed_log 1.1.0 2026-10-29)"
}

commit_release() {
  fixture_git add -A
  fixture_git commit -qm 'chore(release): v1.1.0'
  HEAD_SHA="$(fixture_git rev-parse HEAD)"
}

run_diff() {
  run "$SCRIPT" diff --root "$FIXTURE" --base "$BASE_SHA" --head "$HEAD_SHA"
}

# The diff predicate

@test "diff: a release commit as /gaia-release makes it is bookkeeping" {
  apply_release
  commit_release
  run_diff
  [ "$status" -eq 0 ]
  assert_contains 'bookkeeping 1.0.0 -> 1.1.0'
}

@test "diff: a release with no wiki drift, leaving both wiki files alone, is bookkeeping" {
  apply_release
  fixture_git checkout -q -- wiki
  commit_release
  run_diff
  [ "$status" -eq 0 ]
}

@test "diff: a file outside the bookkeeping set is not bookkeeping" {
  apply_release
  write_file a.sh $'echo changed\n'
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains 'a.sh is outside the release bookkeeping set'
}

@test "diff: a required file left unchanged is not bookkeeping" {
  apply_release
  fixture_git checkout -q -- CHANGELOG.md
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains 'CHANGELOG.md did not change'
}

@test "diff: a package.json change beyond its version is not bookkeeping" {
  apply_release
  write_file package.json $'{\n  "name": "gaia",\n  "version": "1.1.0",\n  "private": true,\n  "scripts": {"postinstall": "curl x"}\n}\n'
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains 'package.json changed beyond its version'
}

@test "diff: a package.json that sneaks in a generated key is not bookkeeping" {
  apply_release
  write_file frontend/package.json $'{\n  "name": "frontend",\n  "version": "1.1.0",\n  "private": true,\n  "generated": "x"\n}\n'
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains 'frontend/package.json'
}

@test "diff: a frontend version that disagrees with .gaia/VERSION is not bookkeeping" {
  apply_release
  write_file frontend/package.json "$(package_json frontend 1.2.0)"
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains 'frontend/package.json does not move 1.0.0 to 1.1.0'
}

@test "diff: a manifest that reclassifies a file is not bookkeeping" {
  apply_release
  write_file .gaia/manifest.json $'{\n  "files": {\n    "a.sh": "shared"\n  },\n  "generated": "x",\n  "version": "1.1.0"\n}\n'
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains '.gaia/manifest.json changed beyond its version'
}

@test "diff: prose added under the graduated CHANGELOG heading is not bookkeeping" {
  apply_release
  changelog 1.1.0 1.1.0 | awk '$0 == "### Added" { print "Run this command first."; print "" } { print }' > "$FIXTURE/CHANGELOG.md"
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains 'CHANGELOG.md changed beyond graduating'
}

@test "diff: a CHANGELOG with no release link is not bookkeeping" {
  apply_release
  changelog 1.1.0 1.1.0 | grep -vF '[1.1.0]: ' > "$FIXTURE/CHANGELOG.md"
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains 'one [1.1.0] heading and one release link'
}

@test "diff: free text in the release link middle is not bookkeeping" {
  apply_release
  changelog 1.1.0 1.1.0 | sed 's|^\[1.1.0\]: https://github.com/example/repo/|[1.1.0]: https://github.com/Run this command first/|' > "$FIXTURE/CHANGELOG.md"
  grep -qF 'Run this command first' "$FIXTURE/CHANGELOG.md" || return 1
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains 'one [1.1.0] heading and one release link'
}

@test "diff: a .gaia/VERSION with a second line is not bookkeeping" {
  apply_release
  write_file .gaia/VERSION $'1.1.0\nextra\n'
  commit_release
  run_diff
  [ "$status" -eq 1 ]
}

@test "diff: a wiki/.state.json change beyond the evaluated pair is not bookkeeping" {
  apply_release
  write_file wiki/.state.json $'{\n  "version": 1,\n  "last_evaluated_sha": "2222",\n  "last_evaluated_at": "x",\n  "last_consolidated_sha": "bbbb"\n}\n'
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains 'wiki/.state.json changed beyond'
}

@test "diff: a wiki/log.md that is not the release scrub is not bookkeeping" {
  apply_release
  printf '%s\nAn instruction for Claude.\n' "$(scrubbed_log 1.1.0 2026-10-29)" > "$FIXTURE/wiki/log.md"
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains 'wiki/log.md is not the release scrub'
}

@test "diff: deleting a bookkeeping file is not bookkeeping" {
  apply_release
  rm "$FIXTURE/wiki/log.md"
  commit_release
  run_diff
  [ "$status" -eq 1 ]
  assert_contains 'is not a plain modification'
}

@test "diff: a base that is not a commit is a usage error, not a verdict" {
  run "$SCRIPT" diff --root "$FIXTURE" --base deadbeef
  [ "$status" -eq 2 ]
}

# ci mode

stub_gh() {
  STUB_DIRECTORY="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIRECTORY/bin"
  : > "$STUB_DIRECTORY/issues.txt"
  printf '%s\n' "$BASE_SHA" > "$STUB_DIRECTORY/branch-head.txt"
  printf '1 completed success https://example.test/actions/runs/1\n' > "$STUB_DIRECTORY/audit-run.txt"
  printf 'completed success\n' > "$STUB_DIRECTORY/workflow-run.txt"
  cat > "$STUB_DIRECTORY/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") cat "$STUB_DIRECTORY/issues.txt" ;;
  api\ repos/*/commits/*) cat "$STUB_DIRECTORY/branch-head.txt" ;;
  api\ repos/*/actions/workflows/audit-ci-tests.yml/*) cat "$STUB_DIRECTORY/audit-run.txt" ;;
  api\ repos/*/actions/workflows/*) cat "$STUB_DIRECTORY/workflow-run.txt" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$STUB_DIRECTORY/bin/gh"
  export STUB_DIRECTORY
  export PATH="$STUB_DIRECTORY/bin:$PATH"
}

run_ci() {
  run "$SCRIPT" ci --root "$FIXTURE" --event "${1:-pull_request}" --repository example/repo \
    --base "$BASE_SHA" --head "$HEAD_SHA" --workflow distribution-harness.yml
}

@test "ci: a bookkeeping change on green main's head takes the fast path" {
  command -v node >/dev/null || skip "node not installed"
  apply_release
  commit_release
  stub_gh
  run_ci
  [ "$status" -eq 0 ]
  assert_contains 'fast=true'
}

@test "ci: a change that is not bookkeeping runs every gate" {
  apply_release
  write_file a.sh $'echo changed\n'
  commit_release
  stub_gh
  run_ci
  [ "$status" -eq 0 ]
  assert_contains 'fast=false'
}

@test "ci: a pull request built on a stale base runs every gate" {
  apply_release
  commit_release
  stub_gh
  printf 'ffffffffffffffffffffffffffffffffffffffff\n' > "$STUB_DIRECTORY/branch-head.txt"
  run_ci
  [ "$status" -eq 0 ]
  assert_contains 'fast=false'
  assert_contains 'not the head of main'
}

@test "ci: a push does not ask for the branch head, which has already moved to the commit" {
  command -v node >/dev/null || skip "node not installed"
  apply_release
  commit_release
  stub_gh
  printf '%s\n' "$HEAD_SHA" > "$STUB_DIRECTORY/branch-head.txt"
  run_ci push
  [ "$status" -eq 0 ]
  assert_contains 'fast=true'
}

@test "ci: an open ci-red-main issue runs every gate" {
  apply_release
  commit_release
  stub_gh
  printf '3100 https://example.test/issues/3100\n' > "$STUB_DIRECTORY/issues.txt"
  run_ci
  [ "$status" -eq 0 ]
  assert_contains 'fast=false'
}

@test "ci: the workflow's own push run still in progress on the base runs every gate" {
  apply_release
  commit_release
  stub_gh
  printf 'in_progress none\n' > "$STUB_DIRECTORY/workflow-run.txt"
  run_ci
  [ "$status" -eq 0 ]
  assert_contains 'fast=false'
}

@test "ci: a base that is not the head's first parent runs every gate" {
  apply_release
  commit_release
  fixture_git commit -q --allow-empty -m later
  HEAD_SHA="$(fixture_git rev-parse HEAD)"
  stub_gh
  run_ci
  [ "$status" -eq 0 ]
  assert_contains 'fast=false'
}

@test "ci: a bookkeeping change whose manifest check fails is red, not a full run" {
  command -v node >/dev/null || skip "node not installed"
  apply_release
  commit_release
  stub_gh
  MANIFEST_CHECK_FAILS=1 run_ci
  [ "$status" -eq 1 ]
  assert_contains 'fast=false'
  assert_contains 'release manifest --check failed'
}
