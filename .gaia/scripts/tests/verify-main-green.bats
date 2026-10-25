#!/usr/bin/env bats
#
# Requires Bats >= 1.5.0 (the negative `run !` assertions below).
bats_require_minimum_version 1.5.0
#
# Tests for `.gaia/scripts/verify-main-green.sh`, the /gaia-release gate that
# refuses to merge the release pull request or tag while main is red.
#
# Every `gh` call goes to a PATH stub that records its argv and answers from
# fixture files, so the suite is offline and never reads a real repository.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

RELEASE_SHA="cccccccccccccccccccccccccccccccccccccccc"

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIRECTORY/../verify-main-green.sh"
  REPOSITORY_ROOT="$THIS_DIRECTORY/../../.."
  [ -x "$SCRIPT" ]
  STUB_DIRECTORY="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIRECTORY/bin"
  GH_LOG="$STUB_DIRECTORY/argv.log"
  : > "$GH_LOG"
  : > "$STUB_DIRECTORY/issues.txt"
  printf '%s\n' "$RELEASE_SHA" > "$STUB_DIRECTORY/head-sha.txt"
  write_run 40152721968 completed success
  cat > "$STUB_DIRECTORY/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue list")
    [ -f "$STUB_DIRECTORY/issue-list-fails" ] && exit 1
    cat "$STUB_DIRECTORY/issues.txt"
    ;;
  api\ repos/*/commits/*)
    [ -f "$STUB_DIRECTORY/head-sha-fails" ] && exit 1
    cat "$STUB_DIRECTORY/head-sha.txt"
    ;;
  api\ repos/*/actions/workflows/*)
    [ -f "$STUB_DIRECTORY/runs-fail" ] && exit 1
    cat "$STUB_DIRECTORY/run.txt"
    ;;
  *) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIRECTORY/bin/gh"
  export GH_LOG STUB_DIRECTORY
  export PATH="$STUB_DIRECTORY/bin:$PATH"
}

# write_run <id> <status> <conclusion>, the one line the runs query's --jq prints.
write_run() {
  printf '%s %s %s https://example.test/actions/runs/%s\n' "$1" "$2" "$3" "$1" > "$STUB_DIRECTORY/run.txt"
}

no_run() {
  : > "$STUB_DIRECTORY/run.txt"
}

open_issue() {
  printf '3100 https://example.test/issues/3100\n' > "$STUB_DIRECTORY/issues.txt"
}

# Green main proceeds

@test "green main: no open ci-red-main issue and a successful push run exits 0" {
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 0 ]
  assert_contains "$RELEASE_SHA"
}

# Red main refuses

@test "red main: a failed push run refuses with exit 1, naming the run and the repair" {
  write_run 555 completed failure
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 1 ]
  assert_contains "https://example.test/actions/runs/555"
  assert_contains "gh run rerun 555 --failed"
  assert_contains "Fix main"
}

@test "red main: an open ci-red-main issue refuses even when the push run is green" {
  open_issue
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 1 ]
  assert_contains "https://example.test/issues/3100"
}

@test "red main: an open ci-red-main issue wins over an in-progress push run" {
  open_issue
  write_run 556 in_progress none
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 1 ]
}

@test "red main: a cancelled or skipped push run is not success and refuses" {
  write_run 557 completed cancelled
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 1 ]
  write_run 558 completed skipped
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 1 ]
}

@test "pending: an in-progress push run refuses with exit 3 and says how to wait" {
  write_run 559 in_progress none
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 3 ]
  assert_contains "gh run watch 559"
}

@test "pending: a queued push run refuses with exit 3" {
  write_run 560 queued none
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 3 ]
}

# Absent or unreadable signal refuses

@test "absent signal: no push run for the release commit refuses with exit 2" {
  no_run
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 2 ]
  assert_contains "$RELEASE_SHA"
}

@test "unreadable signal: a failed issue listing refuses with exit 2" {
  touch "$STUB_DIRECTORY/issue-list-fails"
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 2 ]
}

@test "unreadable signal: a failed runs query refuses with exit 2" {
  touch "$STUB_DIRECTORY/runs-fail"
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 2 ]
}

@test "unreadable signal: an unresolvable branch head refuses with exit 2" {
  touch "$STUB_DIRECTORY/head-sha-fails"
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 2 ]
}

@test "unreadable signal: a runs line in an unexpected shape refuses with exit 2" {
  printf 'garbage\n' > "$STUB_DIRECTORY/run.txt"
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 2 ]
}

# What it reads

@test "the runs query asks for push runs of the audit workflow on the branch at the release commit" {
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 0 ]
  grep -qF -- "repos/example/repo/actions/workflows/audit-ci-tests.yml/runs?event=push&branch=main&head_sha=${RELEASE_SHA}" "$GH_LOG"
}

@test "the issue listing reads open issues carrying the ci-red-main label" {
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 0 ]
  grep -qF -- "issue list --repo example/repo --label ci-red-main --state open" "$GH_LOG"
}

@test "--sha checks that commit and never resolves the branch head" {
  run "$SCRIPT" --repo example/repo --branch main --sha dddddddddddddddddddddddddddddddddddddddd
  [ "$status" -eq 0 ]
  grep -qF -- "head_sha=dddddddddddddddddddddddddddddddddddddddd" "$GH_LOG"
  run ! grep -qF -- "/commits/" "$GH_LOG"
}

@test "the names it reads match the workflow and the reporter that write them" {
  grep -qxF -- "name: 'GAIA: Audit CI Tests'" "$REPOSITORY_ROOT/.github/workflows/audit-ci-tests.yml"
  grep -qF -- "name: Audit CI Tests" "$REPOSITORY_ROOT/.github/workflows/audit-ci-tests.yml"
  grep -qxF -- 'readonly LABEL_NAME="ci-red-main"' "$REPOSITORY_ROOT/.gaia/tests/report-main-status.sh"
}

# Usage errors

@test "usage error: an unknown flag exits 2" {
  run "$SCRIPT" --skip-check
  [ "$status" -eq 2 ]
}

@test "usage error: a value-taking flag with no value exits 2" {
  run "$SCRIPT" --sha
  [ "$status" -eq 2 ]
}
