#!/usr/bin/env bats
#
# Suite for .gaia/scripts/debt-source-report.sh: the maintainer-only report that
# reads the source line off tech-debt issues. Every fixture is written under
# $BATS_TEST_TMPDIR in the REST shape the script reads, and each body's source
# line comes from the library's own writer, so the fixtures cannot drift from
# it; the literal-pin case below keeps writer and reader from drifting together.
# A gh stub on PATH logs its arguments and answers each read from a file.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/debt-source-report.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# shellcheck disable=SC2154,SC2030,SC2031
# bats sets $stderr_lines under run --separate-stderr, and runs each test in a subshell.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/debt-source-report.sh"
  # shellcheck source=/dev/null
  . "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/debt-source-lib.sh"
  TMP="$BATS_TEST_TMPDIR"
  KEY='<!-- gaia-debt-key: v1 class=a path=src/x.ts line=1 -->'
  SINCE='2026-11-01T00:00:00Z'
  IN='2026-11-02T10:00:00Z'
  OUT='2026-10-20T10:00:00Z'
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  *"/issues?"*)
    [ -z "${GH_FAIL_ISSUES:-}" ] || exit 1
    cat "$GH_ISSUES_OUT"
    ;;
  *"/pulls?"*)
    [ -z "${GH_FAIL_PULLS:-}" ] || exit 1
    cat "$GH_PULLS_OUT"
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$TMP/bin/gh"
  export GH_LOG="$TMP/gh.log"
  : >"$GH_LOG"
  printf '[]' >"$TMP/empty.json"
}

line_for() { gaia_debt_source_line_for_branch "$1"; }

# body_for <branch>: a filed body, key line then source line.
body_for() { printf '%s\n%s\n\n**Location:** x\n' "$KEY" "$(line_for "$1")"; }

# issue <number> <created_at> <labels,csv> <body> [<state>]
issue() {
  jq -nc --argjson n "$1" --arg c "$2" --arg l "$3" --arg b "$4" --arg s "${5:-open}" \
    '{number:$n,state:$s,labels:($l|split(",")|map(select(. != "")|{name:.})),body:$b,created_at:$c}'
}

# pull <number> <head> <created_at> <merged_at|null>
pull() {
  jq -nc --argjson n "$1" --arg h "$2" --arg c "$3" --arg m "$4" \
    '{number:$n,head:{ref:$h},created_at:$c,merged_at:(if $m == "null" then null else $m end)}'
}

# write_array <file> <json>...
write_array() {
  local file="$1"
  shift
  printf '%s\n' "$@" | jq -s '.' >"$file"
}

report() { run --separate-stderr bash "$SCRIPT" "$@"; }

assert_refused() {
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "${stderr_lines[0]}" == debt-source-report:* ]]
}

@test "filed counts whole-line matches over the threshold and exits 1" {
  write_array "$TMP/i.json" \
    "$(issue 1 "$OUT" tech-debt "$(body_for debt/sweep-x)" open)" \
    "$(issue 2 "$OUT" tech-debt "$(body_for debt/sweep-x)" closed)" \
    "$(issue 3 "$IN" tech-debt "$(body_for debt/sweep-x)" open)" \
    "$(issue 4 "$IN" tech-debt "$(body_for debt/sweep-x)" closed)" \
    "$(issue 5 "$IN" tech-debt "$(body_for debt/sweep-x)" open)" \
    "$(issue 6 "$IN" tech-debt "$(body_for feat/other)")" \
    "$(issue 7 "$IN" tech-debt "$(body_for feat/other)")" \
    "$(issue 8 "$IN" tech-debt "$(body_for debt/sweep-x2)")" \
    "$(issue 9 "$IN" tech-debt "$(body_for debt/sweep)")" \
    "$(issue 10 "$IN" tech-debt "$KEY
see $(line_for debt/sweep-x) inside a sentence")"
  report filed --branch debt/sweep-x --threshold 4 --issues-file "$TMP/i.json"
  [ "$status" -eq 1 ]
  [ "$output" = "$(printf 'filed 5\nverdict over')" ]
}

@test "filed defaults the threshold to four and passes at four" {
  write_array "$TMP/i.json" \
    "$(issue 1 "$IN" tech-debt "$(body_for debt/sweep-y)")" \
    "$(issue 2 "$IN" tech-debt "$(body_for debt/sweep-y)")" \
    "$(issue 3 "$IN" tech-debt "$(body_for debt/sweep-y)")" \
    "$(issue 4 "$IN" tech-debt "$(body_for debt/sweep-y)")"
  report filed --branch debt/sweep-y --issues-file "$TMP/i.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'filed 4\nverdict pass')" ]
}

@test "filed matches a literal pinned line for both branch spellings" {
  write_array "$TMP/i.json" \
    "$(issue 1 "$IN" tech-debt "$KEY
<!-- gaia-debt-source: v1 branch=ce624e2ca1a2 -->")"
  report filed --branch debt/1234-foo --issues-file "$TMP/i.json"
  [ "$output" = "$(printf 'filed 1\nverdict pass')" ]
  report filed --branch worktree-debt+1234-foo --issues-file "$TMP/i.json"
  [ "$output" = "$(printf 'filed 1\nverdict pass')" ]
}

@test "filed matches the whole line only, tolerating one trailing carriage return" {
  local source_line
  source_line="$(line_for debt/w)"
  write_array "$TMP/i.json" \
    "$(issue 1 "$IN" tech-debt "$(printf '%s\r\n%s\r\nrest' "$KEY" "$source_line")")" \
    "$(issue 2 "$IN" tech-debt "$KEY
 $source_line")" \
    "$(issue 3 "$IN" tech-debt "$KEY
$source_line ")" \
    "$(issue 4 "$IN" tech-debt "$KEY
$source_line
$source_line")" \
    "$(issue 5 "$IN" tech-debt "$KEY
text $source_line more")"
  report filed --branch debt/w --issues-file "$TMP/i.json"
  [ "$output" = "$(printf 'filed 2\nverdict pass')" ]
}

@test "filed ignores pull request entries and issues without the tech-debt label" {
  local body
  body="$(body_for debt/p)"
  write_array "$TMP/i.json" \
    "$(issue 1 "$IN" tech-debt "$body")" \
    "$(issue 2 "$IN" tech-debt "$body" | jq -c '. + {pull_request: {url: "u"}}')" \
    "$(issue 3 "$IN" bug "$body")"
  report filed --branch debt/p --issues-file "$TMP/i.json"
  [ "$output" = "$(printf 'filed 1\nverdict pass')" ]
}

# The baseline fixture, shared by the baseline tests.
baseline_fixture() {
  local merged="2026-11-03T10:00:00Z" early="2026-10-30T10:00:00Z"
  write_array "$TMP/p.json" \
    "$(pull 1 debt/101-a "$IN" "$merged")" \
    "$(pull 2 debt/102-b "$IN" "$merged")" \
    "$(pull 3 debt/103-104-batch "$IN" "$merged")" \
    "$(pull 4 debt/108-109-batch "$IN" "$merged")" \
    "$(pull 5 feat/x "$IN" "$merged")" \
    "$(pull 6 debt/105-c "$IN" "$merged")" \
    "$(pull 7 worktree-debt+106-d "$IN" "$merged")" \
    "$(pull 8 debt/107-e "$IN" "$merged")" \
    "$(pull 9 debt/110-f "$early" "$merged")" \
    "$(pull 10 debt/111-g "$OUT" "2026-10-25T10:00:00Z")" \
    "$(pull 11 debt/112-h "$IN" null)"
  write_array "$TMP/i.json" \
    "$(issue 101 "$OUT" tech-debt,severity:minor x)" \
    "$(issue 102 "$OUT" tech-debt,severity:major x)" \
    "$(issue 103 "$OUT" tech-debt,severity:minor x)" \
    "$(issue 104 "$OUT" tech-debt,severity:minor x)" \
    "$(issue 105 "$OUT" tech-debt,severity:minor x)" \
    "$(issue 106 "$OUT" tech-debt,severity:minor x)" \
    "$(issue 108 "$OUT" tech-debt,severity:minor x)" \
    "$(issue 109 "$OUT" tech-debt,severity:major x)" \
    "$(issue 110 "$OUT" tech-debt,severity:minor x)" \
    "$(issue 201 "$IN" tech-debt "$(body_for debt/101-a)")" \
    "$(issue 202 "$IN" tech-debt "$(body_for debt/101-a)")" \
    "$(issue 203 "$IN" tech-debt "$(body_for debt/105-c)")" \
    "$(issue 204 "$IN" tech-debt "$(body_for debt/106-d)")" \
    "$(issue 205 "$IN" tech-debt "$(body_for debt/103-104-batch)")" \
    "$(issue 206 "$IN" tech-debt "$(body_for debt/108-109-batch)")" \
    "$(issue 207 "$IN" tech-debt "$(body_for feat/x)")" \
    "$(issue 208 "$IN" tech-debt "$(body_for feat/x)")" \
    "$(issue 209 "$IN" tech-debt "$(body_for debt/110-f)")" \
    "$(issue 210 "$IN" tech-debt "$(body_for debt/111-g)")"
}

@test "baseline groups merged pulls by drain shape and severity" {
  baseline_fixture
  report baseline --since "$SINCE" --issues-file "$TMP/i.json" --prs-file "$TMP/p.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'single-minor prs 3 filings 4 mean 1.33\nmulti-minor prs 1 members 2 filings 1 per-member 0.50\nother prs 4 filings 3 mean 0.75')" ]
}

@test "baseline prints none for empty groups" {
  write_array "$TMP/p.json" "$(pull 1 feat/y "$IN" "$IN")"
  write_array "$TMP/i.json" "$(issue 1 "$IN" tech-debt "$(body_for feat/y)")"
  report baseline --since "$SINCE" --issues-file "$TMP/i.json" --prs-file "$TMP/p.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'single-minor prs 0 filings 0 mean none\nmulti-minor prs 0 members 0 filings 0 per-member none\nother prs 1 filings 1 mean 1.00')" ]
}

@test "baseline counts two pulls on one head as two pulls sharing one digest" {
  write_array "$TMP/p.json" \
    "$(pull 1 debt/120-x "$IN" "$IN")" \
    "$(pull 2 debt/120-x "$IN" "$IN")"
  write_array "$TMP/i.json" \
    "$(issue 120 "$OUT" tech-debt,severity:minor x)" \
    "$(issue 301 "$IN" tech-debt "$(body_for debt/120-x)")"
  report baseline --since "$SINCE" --issues-file "$TMP/i.json" --prs-file "$TMP/p.json"
  [ "$status" -eq 0 ]
  [[ "$output" == "single-minor prs 2 filings 1 mean 0.50"* ]]
}

@test "baseline puts a drain with two severity labels in other" {
  write_array "$TMP/p.json" "$(pull 1 debt/130-x "$IN" "$IN")"
  write_array "$TMP/i.json" "$(issue 130 "$OUT" tech-debt,severity:minor,severity:major x)"
  report baseline --since "$SINCE" --issues-file "$TMP/i.json" --prs-file "$TMP/p.json"
  [[ "$output" == "single-minor prs 0"* ]]
  [[ "$output" == *"other prs 1 filings 0 mean 0.00" ]]
}

coverage_fixture_unsound() {
  write_array "$TMP/p.json" \
    "$(pull 1 debt/7-a "$IN" "$IN")" \
    "$(pull 2 debt/8-b "$IN" "$IN")"
  write_array "$TMP/i.json" \
    "$(issue 1 "$IN" tech-debt "$(body_for debt/7-a)")" \
    "$(issue 2 "$IN" tech-debt "$(body_for debt/8-b)")" \
    "$(issue 3 "$IN" tech-debt "$(body_for feat/other)")" \
    "$(issue 4 "$IN" tech-debt "$KEY
<!-- gaia-debt-source: v1 branch=detached -->")" \
    "$(issue 5 "$IN" tech-debt "$KEY")" \
    "$(issue 6 "$IN" tech-debt "$KEY
<!-- gaia-debt-source: v1 branch=0123456789a -->")" \
    "$(issue 7 "$IN" tech-debt "$KEY
<!-- gaia-debt-source: v1 branch=unknown -->")" \
    "$(issue 8 "$IN" tech-debt "no key here")" \
    "$(issue 9 "$OUT" tech-debt "$KEY")"
}

@test "coverage reports an unsound record" {
  coverage_fixture_unsound
  report coverage --since "$SINCE" --issues-file "$TMP/i.json" --prs-file "$TMP/p.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'keyed 7 sourced 4 missing 2 unknown 1 unkeyed 1\nunattributed 2\nsound no')" ]
}

@test "coverage reports a sound record" {
  write_array "$TMP/p.json" \
    "$(pull 1 debt/7-a "$IN" "$IN")" \
    "$(pull 2 debt/8-b "$IN" "$IN")"
  write_array "$TMP/i.json" \
    "$(issue 1 "$IN" tech-debt "$(body_for debt/7-a)")" \
    "$(issue 2 "$IN" tech-debt "$(body_for debt/8-b)")" \
    "$(issue 3 "$IN" tech-debt "$KEY
<!-- gaia-debt-source: v1 branch=detached -->")" \
    "$(issue 4 "$OUT" tech-debt "$KEY")"
  report coverage --since "$SINCE" --issues-file "$TMP/i.json" --prs-file "$TMP/p.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'keyed 3 sourced 3 missing 0 unknown 0 unkeyed 0\nunattributed 1\nsound yes')" ]
}

@test "a date and a full timestamp for since give the same output" {
  local date_output
  coverage_fixture_unsound
  write_array "$TMP/i2.json" "$(jq -c '.[]' "$TMP/i.json")" \
    "$(issue 10 "2026-10-31T23:59:59Z" tech-debt "$KEY")"
  report coverage --since 2026-11-01 --issues-file "$TMP/i2.json" --prs-file "$TMP/p.json"
  date_output="$output"
  report coverage --since 2026-11-01T00:00:00Z --issues-file "$TMP/i2.json" --prs-file "$TMP/p.json"
  [ "$output" = "$date_output" ]
  [[ "$output" == "keyed 7 sourced 4 missing 2 unknown 1 unkeyed 1"* ]]
  baseline_fixture
  report baseline --since 2026-11-01 --issues-file "$TMP/i.json" --prs-file "$TMP/p.json"
  date_output="$output"
  report baseline --since 2026-11-01T00:00:00Z --issues-file "$TMP/i.json" --prs-file "$TMP/p.json"
  [ "$output" = "$date_output" ]
}

@test "the read pages through gh api and joins consecutive arrays" {
  printf '[%s]' "$(issue 1 "$IN" tech-debt "$(body_for debt/pg)")" >"$TMP/issues.out"
  printf '[%s]' "$(issue 2 "$IN" tech-debt "$(body_for debt/pg)")" >>"$TMP/issues.out"
  export GH_ISSUES_OUT="$TMP/issues.out"
  PATH="$TMP/bin:$PATH" report filed --branch debt/pg --repo owner/name
  [ "$output" = "$(printf 'filed 2\nverdict pass')" ]
  grep -qxF 'api --paginate repos/owner/name/issues?labels=tech-debt&state=all&per_page=100' "$GH_LOG"
  PATH="$TMP/bin:$PATH" report filed --branch debt/pg
  [ "$output" = "$(printf 'filed 2\nverdict pass')" ]
  grep -qxF 'api --paginate repos/{owner}/{repo}/issues?labels=tech-debt&state=all&per_page=100' "$GH_LOG"
}

@test "the read accepts one merged array" {
  printf '[%s,%s]' "$(issue 1 "$IN" tech-debt "$(body_for debt/pg)")" "$(issue 2 "$IN" tech-debt "$(body_for debt/pg)")" >"$TMP/issues.out"
  export GH_ISSUES_OUT="$TMP/issues.out"
  PATH="$TMP/bin:$PATH" report filed --branch debt/pg
  [ "$output" = "$(printf 'filed 2\nverdict pass')" ]
}

@test "baseline and coverage read the closed pulls endpoint" {
  export GH_ISSUES_OUT="$TMP/empty.json" GH_PULLS_OUT="$TMP/empty.json"
  PATH="$TMP/bin:$PATH" report baseline --since "$SINCE" --repo owner/name
  [ "$status" -eq 0 ]
  PATH="$TMP/bin:$PATH" report coverage --since "$SINCE" --repo owner/name
  [ "$status" -eq 0 ]
  grep -qxF 'api --paginate repos/owner/name/pulls?state=closed&per_page=100' "$GH_LOG"
}

@test "a failed issues read is a refusal for every subcommand" {
  export GH_FAIL_ISSUES=1 GH_ISSUES_OUT="$TMP/empty.json" GH_PULLS_OUT="$TMP/empty.json"
  PATH="$TMP/bin:$PATH" report filed --branch debt/a
  assert_refused
  PATH="$TMP/bin:$PATH" report baseline --since "$SINCE"
  assert_refused
  PATH="$TMP/bin:$PATH" report coverage --since "$SINCE"
  assert_refused
}

@test "a failed pulls read is a refusal for baseline and coverage" {
  export GH_FAIL_PULLS=1 GH_ISSUES_OUT="$TMP/empty.json" GH_PULLS_OUT="$TMP/empty.json"
  PATH="$TMP/bin:$PATH" report baseline --since "$SINCE"
  assert_refused
  PATH="$TMP/bin:$PATH" report coverage --since "$SINCE"
  assert_refused
}

@test "a bad credentials second page is a refusal" {
  printf '[]\n{"message":"Bad credentials"}\n' >"$TMP/issues.out"
  export GH_ISSUES_OUT="$TMP/issues.out"
  PATH="$TMP/bin:$PATH" report filed --branch debt/a
  assert_refused
}

@test "usage errors and unreadable seams are refusals" {
  printf '{}' >"$TMP/obj.json"
  report
  assert_refused
  report bogus
  assert_refused
  report filed
  assert_refused
  report filed --branch debt/a --threshold -1 --issues-file "$TMP/empty.json"
  assert_refused
  report filed --branch debt/a --threshold x --issues-file "$TMP/empty.json"
  assert_refused
  report coverage --issues-file "$TMP/empty.json" --prs-file "$TMP/empty.json"
  assert_refused
  report baseline --issues-file "$TMP/empty.json" --prs-file "$TMP/empty.json"
  assert_refused
  report baseline --since 2026-13-40 --issues-file "$TMP/empty.json" --prs-file "$TMP/empty.json"
  assert_refused
  report baseline --since 2026-11-01T25:00:00Z --issues-file "$TMP/empty.json" --prs-file "$TMP/empty.json"
  assert_refused
  report filed --branch debt/a --since 2026-11-01 --issues-file "$TMP/empty.json"
  assert_refused
  report filed --branch debt/a --issues-file "$TMP/missing.json"
  assert_refused
  report filed --branch debt/a --issues-file "$TMP/obj.json"
  assert_refused
}

@test "a missing jq is a refusal" {
  local tool tool_path
  mkdir -p "$TMP/nojq"
  for tool in dirname mktemp rm cat cut tr env shasum sha256sum sort uniq; do
    tool_path="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$tool_path" "$TMP/nojq/$tool"
  done
  PATH="$TMP/nojq" run --separate-stderr "$BASH" "$SCRIPT" filed --branch debt/a --issues-file "$TMP/empty.json"
  assert_refused
}
