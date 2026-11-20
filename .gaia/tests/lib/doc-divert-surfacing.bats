#!/usr/bin/env bats
# Doc pins for how a diverted security finding is surfaced and how a transient
# filing is retried. The unit's report carries a count and record paths and no
# finding detail; the main thread's runbook tells the human the count before
# it posts the status and then merges without stopping; the unit re-files each
# retry file every round.
#
# Prose-to-prose only: whether the filing script behaves as the sentences say
# is file-tech-debt.bats's subject.
#
# Assertion style: .claude/rules/bats-assertions.md. `.gaia/tests/` is
# release-excluded, so the UAT ids below are traceability, not shipped prose.

# The pinned sentences carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AGENT="$ROOT/.claude/agents/audit-loop-unit.md"
  PAGE="$ROOT/wiki/concepts/PR Merge Workflow.md"
}

# assert_pinned <file> <literal>: the literal is present in the file.
assert_pinned() {
  grep -qF -- "$2" "$1" || { echo "missing in $1: $2" >&2; return 1; }
}

@test "UAT-038: the unit's report carries diverted_count and diverted_records and no finding detail" {
  assert_pinned "$AGENT" '`diverted_count` (integer), `diverted_records` (array of record paths)'
  assert_pinned "$AGENT" 'The report carries no diverted finding detail (diverts render as a count and record paths only): never a diverted finding'"'"'s key, class, path, title or reason.'
  assert_pinned "$AGENT" 'A diverted finding appears nowhere outside the filing script'"'"'s local record'
}

@test "UAT-038: the runbook surfaces a non-zero diverted count to the human before the status posts, then merges without stopping" {
  assert_pinned "$PAGE" 'surface that count and the `diverted_records` paths to the human before the status is posted, then post and merge without stopping.'
  assert_pinned "$PAGE" 'and nothing about it goes into a PR body, comment or status.'
}

@test "UAT-005: the unit re-files every retry file each round and records filing_pending" {
  assert_pinned "$AGENT" '- Retry pass: run the same command with `--finding <f>` and `--disposition file` once for every file in `<run>/filing-retry/` that an earlier `transient` outcome left, into the same outcome file. Run it every round, whatever the round'"'"'s own filings did.'
  assert_pinned "$AGENT" 'and the files left in `<run>/filing-retry/` into `filing_pending`'
}
