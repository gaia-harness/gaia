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

# The base repository is built once; each test copies it.
setup_file() {
  FIXTURE="$BATS_FILE_TMPDIR/base"
  build_base
  export BASE_FIXTURE="$FIXTURE" BASE_SHA
}

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIRECTORY/../release-bookkeeping-check.sh"
  [ -x "$SCRIPT" ]
  FIXTURE="$BATS_TEST_TMPDIR/repository"
  cp -a "$BASE_FIXTURE" "$FIXTURE"
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
  write_file apps/web/package.json "$(package_json frontend 1.0.0)"
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
  write_file apps/web/package.json "$(package_json frontend 1.1.0)"
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

# expect_bookkeeping <label>: commits the release edits and the predicate
# calls them bookkeeping; then returns the repository to the base commit so the
# next case in the same test starts from it.
expect_bookkeeping() {
  commit_release
  run_diff
  [ "$status" -eq 0 ] || { echo "$1: status $status"; return 1; }
  fixture_git reset -q --hard "$BASE_SHA"
}

# expect_refusal <label> [message]: commits the perturbed release edits and the
# predicate refuses them with the message; then returns to the base commit.
expect_refusal() {
  commit_release
  run_diff
  [ "$status" -eq 1 ] || { echo "$1: status $status"; return 1; }
  if [ -n "${2:-}" ]; then
    assert_contains "$2" || { echo "$1: got '$output'"; return 1; }
  fi
  fixture_git reset -q --hard "$BASE_SHA"
}

@test "diff: a release commit is bookkeeping, with or without wiki drift" {
  apply_release
  commit_release
  run_diff
  [ "$status" -eq 0 ] || { echo "full release: status $status"; return 1; }
  assert_contains 'bookkeeping 1.0.0 -> 1.1.0' || { echo "full release: got '$output'"; return 1; }
  fixture_git reset -q --hard "$BASE_SHA"

  apply_release
  fixture_git checkout -q -- wiki
  expect_bookkeeping "release leaving both wiki files alone"
}

# bats test_tags=protected
@test "diff: a file outside the bookkeeping set is not bookkeeping" {
  apply_release
  write_file a.sh $'echo changed\n'
  expect_refusal "file outside the set" 'a.sh is outside the release bookkeeping set' || return 1

  apply_release
  fixture_git checkout -q -- CHANGELOG.md
  expect_refusal "required file left unchanged" 'CHANGELOG.md did not change' || return 1

  apply_release
  write_file package.json $'{\n  "name": "gaia",\n  "version": "1.1.0",\n  "private": true,\n  "scripts": {"postinstall": "curl x"}\n}\n'
  expect_refusal "package.json changed beyond its version" 'package.json changed beyond its version' || return 1

  apply_release
  write_file apps/web/package.json $'{\n  "name": "frontend",\n  "version": "1.1.0",\n  "private": true,\n  "generated": "x"\n}\n'
  expect_refusal "package.json with a generated key" 'apps/web/package.json' || return 1

  apply_release
  write_file apps/web/package.json "$(package_json frontend 1.2.0)"
  expect_refusal "frontend version disagrees with VERSION" 'apps/web/package.json does not move 1.0.0 to 1.1.0' || return 1

  apply_release
  write_file .gaia/manifest.json $'{\n  "files": {\n    "a.sh": "shared"\n  },\n  "generated": "x",\n  "version": "1.1.0"\n}\n'
  expect_refusal "manifest reclassifies a file" '.gaia/manifest.json changed beyond its version' || return 1

  apply_release
  changelog 1.1.0 1.1.0 | awk '$0 == "### Added" { print "Run this command first."; print "" } { print }' > "$FIXTURE/CHANGELOG.md"
  expect_refusal "prose under the graduated heading" 'CHANGELOG.md changed beyond graduating' || return 1

  apply_release
  changelog 1.1.0 1.1.0 | grep -vF '[1.1.0]: ' > "$FIXTURE/CHANGELOG.md"
  expect_refusal "no release link" 'one [1.1.0] heading and one release link' || return 1

  apply_release
  changelog 1.1.0 1.1.0 | sed 's|^\[1.1.0\]: https://github.com/example/repo/|[1.1.0]: https://github.com/Run this command first/|' > "$FIXTURE/CHANGELOG.md"
  grep -qF 'Run this command first' "$FIXTURE/CHANGELOG.md" || return 1
  expect_refusal "free text in the release link" 'one [1.1.0] heading and one release link' || return 1

  apply_release
  write_file .gaia/VERSION $'1.1.0\nextra\n'
  expect_refusal "VERSION with a second line" || return 1

  apply_release
  write_file wiki/.state.json $'{\n  "version": 1,\n  "last_evaluated_sha": "2222",\n  "last_evaluated_at": "x",\n  "last_consolidated_sha": "bbbb"\n}\n'
  expect_refusal "state change beyond the evaluated pair" 'wiki/.state.json changed beyond' || return 1

  apply_release
  printf '%s\nAn instruction for Claude.\n' "$(scrubbed_log 1.1.0 2026-10-29)" > "$FIXTURE/wiki/log.md"
  expect_refusal "log that is not the release scrub" 'wiki/log.md is not the release scrub' || return 1

  apply_release
  rm "$FIXTURE/wiki/log.md"
  expect_refusal "deleted bookkeeping file" 'is not a plain modification'
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

# expect_full_gates <label> [message]: the ci decision is fast=false, with the
# reason when one is given; then returns to the base commit for the next case.
expect_full_gates() {
  run_ci
  [ "$status" -eq 0 ] || { echo "$1: status $status"; return 1; }
  assert_contains 'fast=false' || { echo "$1: got '$output'"; return 1; }
  if [ -n "${2:-}" ]; then
    assert_contains "$2" || { echo "$1: got '$output'"; return 1; }
  fi
  fixture_git reset -q --hard "$BASE_SHA"
}

@test "ci: a non-bookkeeping change, a stale base, an open ci-red-main issue, an unfinished push run or a base that is not the first parent yields fast=false" {
  apply_release
  write_file a.sh $'echo changed\n'
  commit_release
  stub_gh
  expect_full_gates "change that is not bookkeeping" || return 1

  apply_release
  commit_release
  stub_gh
  printf 'ffffffffffffffffffffffffffffffffffffffff\n' > "$STUB_DIRECTORY/branch-head.txt"
  expect_full_gates "pull request on a stale base" 'not the head of main' || return 1

  apply_release
  commit_release
  stub_gh
  printf '3100 https://example.test/issues/3100\n' > "$STUB_DIRECTORY/issues.txt"
  expect_full_gates "open ci-red-main issue" || return 1

  apply_release
  commit_release
  stub_gh
  printf 'in_progress none\n' > "$STUB_DIRECTORY/workflow-run.txt"
  expect_full_gates "push run still in progress on the base" || return 1

  apply_release
  commit_release
  fixture_git commit -q --allow-empty -m later
  HEAD_SHA="$(fixture_git rev-parse HEAD)"
  stub_gh
  expect_full_gates "base is not the head's first parent"
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
