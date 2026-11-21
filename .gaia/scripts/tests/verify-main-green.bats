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

# bats test_tags=protected
@test "red main refusals exit 1: failed run, open ci-red-main issue, issue over in-progress run, cancelled and skipped run" {
  write_run 555 completed failure
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 1 ] || { echo "case failed run: got $status"; return 1; }
  assert_contains "https://example.test/actions/runs/555" || { echo "case failed run: run not named"; return 1; }
  assert_contains "gh run rerun 555 --failed" || { echo "case failed run: no repair"; return 1; }
  assert_contains "Fix main" || { echo "case failed run: no Fix main"; return 1; }

  write_run 40152721968 completed success
  open_issue
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 1 ] || { echo "case open issue, green run: got $status"; return 1; }
  assert_contains "https://example.test/issues/3100" || { echo "case open issue, green run: issue not named"; return 1; }

  write_run 556 in_progress none
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 1 ] || { echo "case open issue over in-progress run: got $status"; return 1; }

  : > "$STUB_DIRECTORY/issues.txt"
  local conclusion
  for conclusion in cancelled skipped; do
    write_run 557 completed "$conclusion"
    run "$SCRIPT" --repo example/repo --branch main
    [ "$status" -eq 1 ] || { echo "case $conclusion run: got $status"; return 1; }
  done
}

# The reporter keys each workflow's issue by title, so the release gate must
# read the label alone: a title or search filter would miss the distribution
# harness's issue while Audit CI Tests is green.
@test "the issue listing reads open issues by the ci-red-main label only" {
  open_issue
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 1 ]
  grep -qF -- "issue list --repo example/repo --label ci-red-main --state open" "$GH_LOG"
  grep -E '^issue list ' "$GH_LOG" | grep -qE -- '--search|in:title|Audit CI Tests' && return 1
  assert_contains "the workflow its title names"
}

@test "pending runs exit 3: in-progress says how to wait, queued" {
  write_run 559 in_progress none
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 3 ] || { echo "case in-progress: got $status"; return 1; }
  assert_contains "gh run watch 559" || { echo "case in-progress: no wait hint"; return 1; }

  write_run 560 queued none
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 3 ] || { echo "case queued: got $status"; return 1; }
}

@test "absent or unreadable signal exits 2: no run, failed issue listing, failed runs query, unresolvable head, malformed runs line" {
  no_run
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 2 ] || { echo "case no run: got $status"; return 1; }
  assert_contains "$RELEASE_SHA" || { echo "case no run: sha not named"; return 1; }

  write_run 40152721968 completed success
  local flag
  for flag in issue-list-fails runs-fail head-sha-fails; do
    touch "$STUB_DIRECTORY/$flag"
    run "$SCRIPT" --repo example/repo --branch main
    [ "$status" -eq 2 ] || { echo "case $flag: got $status"; return 1; }
    rm -f "$STUB_DIRECTORY/$flag"
  done

  printf 'garbage\n' > "$STUB_DIRECTORY/run.txt"
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 2 ] || { echo "case malformed runs line: got $status"; return 1; }
}

# What it reads

@test "the runs query asks for push runs of the audit workflow on the branch at the release commit" {
  run "$SCRIPT" --repo example/repo --branch main
  [ "$status" -eq 0 ]
  grep -qF -- "repos/example/repo/actions/workflows/audit-ci-tests.yml/runs?event=push&branch=main&head_sha=${RELEASE_SHA}" "$GH_LOG"
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

@test "usage errors exit 2: unknown flag, flag without value" {
  run "$SCRIPT" --skip-check
  [ "$status" -eq 2 ] || { echo "case unknown flag: got $status"; return 1; }
  run "$SCRIPT" --sha
  [ "$status" -eq 2 ] || { echo "case flag without value: got $status"; return 1; }
}
