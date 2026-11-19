#!/usr/bin/env bats
#
# Doc-conformance suite for /gaia-debt's backlog-ordering `--jq` query
# (.claude/skills/gaia/references/debt.md), the most load-bearing line in the
# file: the deterministic sort every subcommand (list, why, fix) shares, and
# the source of the `labels`, `key`, `body`, and `footprint` fields the
# clustering pass, the two security screens, and the spec screen all read.
#
# The executable render is the gate: it extracts the `--jq` PROGRAM TEXT out of
# debt.md with awk, feeds it a synthetic fixture
# (fixtures/debt-query/backlog.json, six issues, none real), and asserts on
# the emitted objects. Do not "simplify" this back into a hand-copied program:
# rendering it from the artifact is what makes the gate measure debt.md
# instead of measuring itself.
#
# The render cases assert one key at a time (`.key.line`, `.footprint`,
# `.labels`, `.body`), never a whole-object comparison, so a field added to
# the program later does not break a case that is correct by design.
#
# The one structural check anchors on the FIRST `--jq '` line in debt.md,
# which is the ordering query inside the `## Read and order the backlog` fence.
#
# Engine note: `gh --jq` runs gojq (Go regexp, where `(?m)` enables line
# anchors); a local `jq` runs Oniguruma (where `^` is always a line anchor and
# `(?m)` means dotall, harmless here since the pattern contains no `.`). The
# one frozen form in debt.md is correct under both. The render cases run under
# whichever engine is on PATH and skip with a message if neither is present;
# the ubuntu-latest image ships `jq`, so they run in CI.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DEBT_MD="$REPO_ROOT/.claude/skills/gaia/references/debt.md"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/debt-query/backlog.json"
}

# Resolves to `jq` or `gojq`, whichever is on PATH; empty if neither.
jq_bin() {
  if command -v jq >/dev/null 2>&1; then
    echo jq
  elif command -v gojq >/dev/null 2>&1; then
    echo gojq
  fi
}

# report_engines: prints, on one stdout line, the space-separated jq
# binaries on PATH (some of jq/gojq, or nothing), and states on stderr which
# of the two is absent. The ordering query is body-scoped, so its newline
# exclusion behaves differently under jq's Oniguruma and gojq's Go RE2 in
# principle; a body-scoped case drives every engine present rather than the
# first one found, and reports an absent engine explicitly rather than
# silently skipping it.
report_engines() {
  local present="" absent=""
  command -v jq >/dev/null 2>&1 && present="jq" || absent="jq"
  if command -v gojq >/dev/null 2>&1; then
    present="${present:+$present }gojq"
  else
    absent="${absent:+$absent }gojq"
  fi
  if [ -n "$absent" ]; then
    echo "engine accounting: absent from PATH: ${absent}" >&2
  fi
  echo "engine accounting: exercised: ${present:-none}" >&2
  printf '%s\n' "$present"
}

# The ordering query's whole fenced code block, anchored on the unique
# `--jq '` line: the last ``` fence before it opens the block, the first ```
# fence after it closes it.
extract_query_fence() {
  local jq_line start end
  jq_line=$(grep -n -F -- "--jq '" "$DEBT_MD" | head -1 | cut -d: -f1)
  start=$(awk -v jq_line_number="$jq_line" 'NR < jq_line_number && /^```/ { fence_start = NR } END { print fence_start + 0 }' "$DEBT_MD")
  end=$(awk -v jq_line_number="$jq_line" 'NR > jq_line_number && /^```/ { print NR; exit }' "$DEBT_MD")
  sed -n "${start},${end}p" "$DEBT_MD"
}

# The bare `--jq` PROGRAM TEXT, from the line after the `--jq '` anchor up to
# the line whose only non-whitespace content is a closing `'`. The render
# cases execute this directly; it is never hand-copied into the suite.
extract_jq_program() {
  awk -v single_quote="'" '
    index($0, "--jq " single_quote) { found = 1; next }
    found && $0 ~ "^[ \t]*" single_quote "[ \t]*$" { exit }
    found { print }
  ' "$DEBT_MD"
}

# Runs the extracted program against the fixture and prints the JSON result.
# Callers guard with `[ -n "$(jq_bin)" ] || skip ...` first.
render_backlog() {
  "$(jq_bin)" "$(extract_jq_program)" "$FIXTURE"
}

# issue_of <number> <output>: the rendered object of one issue number.
issue_of() {
  jq --arg issue_number "$1" '.[] | select(.number == ($issue_number | tonumber))' <<<"$2"
}

# fail_case <case name>: names the failing case on stderr and fails.
fail_case() {
  printf 'failed case: %s\n' "$1" >&2
  return 1
}

@test "the ordering query keeps --limit 1000" {
  block="$(extract_query_fence)"
  printf '%s\n' "$block" | grep -qF -- "--limit 1000" || return 1
}

@test "ordering query ranks severity, investigate and unlabelled issues" {
  bin="$(jq_bin)"
  [ -n "$bin" ] || skip "neither jq nor gojq on PATH"
  output="$(render_backlog)"
  investigate="$(issue_of 106 "$output")"
  unlabelled="$(issue_of 104 "$output")"
  [ "$(jq '.sev' <<<"$investigate")" = "0" ] || fail_case "an investigate-graded issue ranks 0"
  # Last in the whole ordering, below every suggestion and below the
  # unlabelled issue, which is what "not an ordinal severity" costs it.
  [ "$(jq '.[-1].number' <<<"$output")" = "106" ] || fail_case "the investigate issue sorts below the suggestion band"
  [ "$(jq '.sev' <<<"$unlabelled")" = "1" ] || fail_case "an unlabelled issue still ranks 1"
  [ "$(jq '.[0].number' <<<"$output")" = "101" ] || fail_case "the top-severity issue sorts first"
}

@test "ordering query projects labels, key line, footprint and body" {
  bin="$(jq_bin)"
  [ -n "$bin" ] || skip "neither jq nor gojq on PATH"
  output="$(render_backlog)"
  issue_101="$(issue_of 101 "$output")"
  issue_102="$(issue_of 102 "$output")"
  issue_103="$(issue_of 103 "$output")"
  issue_104="$(issue_of 104 "$output")"
  [ "$(jq -r '.[0].labels | type' <<<"$output")" = "array" ] || fail_case "labels project as an array"
  [ "$(jq -r '.[0].labels[0] | type' <<<"$output")" = "string" ] || fail_case "labels project as strings"
  [ "$(jq '.key.line' <<<"$issue_101")" = "4" ] || fail_case "key.line 4"
  [ "$(jq -r '.key.line | type' <<<"$issue_101")" = "number" ] || fail_case "key.line coerces to a number"
  [ "$(jq '.key.line' <<<"$issue_102")" = "42" ] || fail_case "key.line 42"
  [ "$(jq -r '.footprint' <<<"$issue_101")" = "narrow" ] || fail_case "footprint narrow, prefix stripped"
  [ "$(jq -r '.footprint' <<<"$issue_102")" = "wide" ] || fail_case "footprint wide, prefix stripped"
  [ "$(jq '.key' <<<"$issue_103")" = "null" ] || fail_case "a malformed key emits key: null"
  [ "$(jq '.footprint' <<<"$issue_103")" = "null" ] || fail_case "a malformed key emits footprint: null"
  [ "$(jq '.key' <<<"$issue_104")" = "null" ] || fail_case "an unlabelled issue emits key: null"
  [ "$(jq '.footprint' <<<"$issue_104")" = "null" ] || fail_case "an unlabelled issue emits footprint: null"
  for issue_number in 101 102 103 104; do
    issue="$(issue_of "$issue_number" "$output")"
    [ "$(jq -r '.body | type' <<<"$issue")" = "string" ] || fail_case "issue ${issue_number} emits a string body"
    body_length="$(jq -r '.body | length' <<<"$issue")"
    [ "$body_length" -gt 0 ] || fail_case "issue ${issue_number} emits a non-empty body"
  done
}

@test "ordering query key capture on spaced, continued and multiline input" {
  engines="$(report_engines)"
  [ -n "$engines" ] || skip "neither jq nor gojq on PATH"
  two_keys_fixture="$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/two-keys-one-line-issues.json"
  decoy="$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/multiline-decoy-body.txt"
  [ -f "$two_keys_fixture" ] || {
    echo "fixture absent: ${two_keys_fixture}" >&2
    return 1
  }
  [ -f "$decoy" ] || {
    echo "fixture absent: ${decoy}" >&2
    return 1
  }
  program="$(extract_jq_program)"

  for engine in $engines; do
    # A spaced path key parses verbatim with its own line number.
    output="$("$engine" "$program" "$FIXTURE")"
    issue_105="$("$engine" --arg issue_number 105 '.[] | select(.number == ($issue_number | tonumber))' <<<"$output")"
    path="$("$engine" -r '.key.path' <<<"$issue_105")"
    line="$("$engine" '.key.line' <<<"$issue_105")"
    if [ "$path" != "wiki/concepts/PR Merge Workflow.md" ] || [ "$line" != "175" ]; then
      echo "failed case: spaced path key; engine ${engine}: key.path=${path} key.line=${line}" >&2
      return 1
    fi

    # A two-key continuation line yields the first key's own path and line.
    output="$("$engine" "$program" "$two_keys_fixture")"
    issue="$("$engine" '.[] | select(.number == 9001)' <<<"$output")"
    path="$("$engine" -r '.key.path' <<<"$issue")"
    line="$("$engine" '.key.line' <<<"$issue")"
    if [ "$path" != "wiki/concepts/PR Merge Workflow.md" ] || [ "$line" != "7" ]; then
      echo "failed case: two-key continuation line; engine ${engine}: key.path=${path} key.line=${line}" >&2
      return 1
    fi

    # The multiline decoy body does not swallow the real key.
    wrapped="${BATS_TEST_TMPDIR}/decoy-issue-${engine}.json"
    "$engine" -n --rawfile body "$decoy" \
      '[{number: 9002, title: "decoy", createdAt: "2026-01-06T00:00:00Z", labels: [], body: $body}]' \
      >"$wrapped"
    output="$("$engine" "$program" "$wrapped")"
    issue="$("$engine" '.[] | select(.number == 9002)' <<<"$output")"
    path="$("$engine" -r '.key.path' <<<"$issue")"
    case "$path" in
      *$'\n'*)
        echo "failed case: multiline decoy; engine ${engine}: the capture leaked a newline into the path: ${path}" >&2
        return 1
        ;;
    esac
    if [ "$path" != "app/real.ts" ]; then
      echo "failed case: multiline decoy; engine ${engine}: the capture did not land on the real key: ${path}" >&2
      return 1
    fi
  done
}
