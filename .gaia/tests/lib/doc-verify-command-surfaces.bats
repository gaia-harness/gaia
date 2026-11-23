#!/usr/bin/env bats
# Pins for the shipped surfaces that tell the maintainer how to run the round
# verification: the audit-loop-unit agent prescribes the background round run
# as one plain command, the audit round procedure says the runner writes its
# own completion signal, and no surface appends the exit line after it.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned literals carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WIKI="$ROOT/wiki/concepts/PR Merge Workflow.md"
  ROUNDS="$ROOT/wiki/concepts/Audit Round Procedure.md"
  RULE="$ROOT/.claude/rules/pr-merge.md"
  AGENT="$ROOT/.claude/agents/audit-loop-unit.md"
}

# maintainer_text <file>: only the lines inside maintainer-only marker pairs.
maintainer_text() {
  awk '
    /<!-- gaia:maintainer-only:start -->/ { inside = 1; next }
    /<!-- gaia:maintainer-only:end -->/ { inside = 0; next }
    inside { print }
  ' "$1"
}

# block_has <file> <literal>: rc 0 when a maintainer-only block carries it.
block_has() {
  maintainer_text "$1" | grep -qF -- "$2"
}

# assert_block_pinned <file> <literal>: a maintainer-only block of the file
# carries the literal.
assert_block_pinned() {
  block_has "$1" "$2" || { echo "missing in a maintainer-only block of $1: $2" >&2; return 1; }
}

@test "the agent prescribes the background round run as one plain command the runner signals" {
  assert_block_pinned "$AGENT" 'as exactly `bash <root>/.gaia/tests/verify-harness.sh round < /dev/null > <scratch>/gate-<r>-<k>.log 2>&1`'
  assert_block_pinned "$AGENT" 'The runner writes `verify-harness exit <status>` as its own last line'
  assert_block_pinned "$ROUNDS" 'the runner writes its own completion signal'
}

@test "no surface prescribes appending the exit line after the round run" {
  local surface compound="; printf 'verify-harness exit"
  for surface in "$AGENT" "$ROUNDS" "$WIKI" "$RULE"; do
    grep -qF -- "$compound" "$surface" && { echo "compound round spelling in $surface" >&2; return 1; }
  done
  true
}
