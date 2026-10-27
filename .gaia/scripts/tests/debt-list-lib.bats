#!/usr/bin/env bats
#
# Suite for .gaia/scripts/debt-list-lib.sh: the complete, paginated read of the
# tech-debt issue lists. A `gh` stub on PATH serves the pages, so a short read
# (a first page only, or a failure mid-pagination) is observable.
#
# Set DEBT_LIST_LIB to run the same assertions against a scratch copy.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/debt-list-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIB="${DEBT_LIST_LIB:-$REAL_ROOT/.gaia/scripts/debt-list-lib.sh}"
  # shellcheck source=/dev/null
  . "$LIB"
  STUB="$BATS_TEST_TMPDIR/stub"
  OUT="$BATS_TEST_TMPDIR/out.json"
  mkdir -p "$STUB" "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB/log"
cat "$STUB/pages" 2>/dev/null
if [ -f "$STUB/gh-error" ]; then
  cat "$STUB/gh-error" >&2
  exit 1
fi
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export STUB PATH
}

# rest_issues <first> <count>: a JSON array of REST-shaped issues.
rest_issues() {
  jq -n -c --argjson first "$1" --argjson count "$2" \
    '[range($first; $first + $count) | {number: ., body: "b\(.)", labels: [{name: "tech-debt", color: "ffffff"}], state_reason: "completed"}]'
}

@test "two pages printed as consecutive arrays yield every entry" {
  { rest_issues 1 100; rest_issues 101 3; } >"$STUB/pages"
  run gaia_debt_list_read owner/name closed "$OUT"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' "$OUT")" -eq 103 ]
  [ "$(jq -r '.[102].number' "$OUT")" -eq 103 ]
}

@test "one merged array is read as the same list" {
  jq -n -c '[range(1; 104) | {number: ., body: "x", labels: [], state_reason: null}]' >"$STUB/pages"
  run gaia_debt_list_read owner/name open "$OUT"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' "$OUT")" -eq 103 ]
}

@test "the read asks gh to paginate the labeled issues of the requested state" {
  rest_issues 1 1 >"$STUB/pages"
  run gaia_debt_list_read owner/name closed "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB/log")" = "api --paginate repos/owner/name/issues?labels=tech-debt&state=closed&per_page=100" ]
}

@test "an empty repository passes gh its own owner and repo placeholder" {
  rest_issues 1 1 >"$STUB/pages"
  run gaia_debt_list_read "" open "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB/log")" = "api --paginate repos/{owner}/{repo}/issues?labels=tech-debt&state=open&per_page=100" ]
}

@test "an entry carrying pull_request is dropped" {
  jq -n -c '[{number: 1, body: "a", labels: [], state_reason: null}, {number: 2, body: "b", labels: [], state_reason: null, pull_request: {url: "u"}}]' >"$STUB/pages"
  run gaia_debt_list_read owner/name open "$OUT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.[].number]' "$OUT")" = "[1]" ]
}

@test "state_reason projects to the upper-case stateReason and null stays null" {
  jq -n -c '[
    {number: 1, body: "a", labels: [{name: "wontfix", color: "x"}, {name: "tech-debt", color: "y"}], state_reason: "not_planned"},
    {number: 2, body: null, labels: [], state_reason: null},
    {number: 3, body: "c", labels: [], state_reason: "completed"}]' >"$STUB/pages"
  run gaia_debt_list_read owner/name closed "$OUT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0]' "$OUT")" = '{"number":1,"body":"a","labels":[{"name":"wontfix"},{"name":"tech-debt"}],"stateReason":"NOT_PLANNED"}' ]
  [ "$(jq -c '.[1]' "$OUT")" = '{"number":2,"body":"","labels":[],"stateReason":null}' ]
  [ "$(jq -r '.[2].stateReason' "$OUT")" = "COMPLETED" ]
}

@test "gh failing after one page is a failure, not a shorter list" {
  rest_issues 1 100 >"$STUB/pages"
  printf 'HTTP 502: bad gateway\n' >"$STUB/gh-error"
  run --separate-stderr gaia_debt_list_read owner/name closed "$OUT"
  [ "$status" -eq 1 ]
  [ ! -s "$OUT" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  case "$stderr" in *"bad gateway"*) ;; *) return 1 ;; esac
}

@test "a page that is not an array is a failure" {
  { rest_issues 1 2; printf '{"message":"Not Found"}\n'; } >"$STUB/pages"
  run --separate-stderr gaia_debt_list_read owner/name open "$OUT"
  [ "$status" -eq 1 ]
  [ ! -s "$OUT" ]
  [ -n "$stderr" ]
}

@test "unparseable output is a failure" {
  printf 'not json at all\n' >"$STUB/pages"
  run --separate-stderr gaia_debt_list_read owner/name open "$OUT"
  [ "$status" -eq 1 ]
  [ ! -s "$OUT" ]
  [ -n "$stderr" ]
}
