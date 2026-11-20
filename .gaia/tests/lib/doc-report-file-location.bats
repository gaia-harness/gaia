#!/usr/bin/env bats
# Doc pin for where a dispatched agent's report file goes. In a linked
# worktree `.gaia/local` and `.notebook` are symlinks into the main checkout,
# so worktree isolation refuses an agent's Write there; the dispatch rule names
# the session scratchpad (or a `mktemp -d` directory) instead.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned sentences carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RULE="$ROOT/.claude/rules/subagent-dispatch.md"
}

# assert_pinned <file> <literal>: the literal is present in the file.
assert_pinned() {
  grep -qF -- "$2" "$1" || { echo "missing in $1: $2" >&2; return 1; }
}

@test "the dispatch rule puts the report file in the scratchpad, never under .gaia/local or .notebook" {
  assert_pinned "$RULE" 'Put the file in the session'"'"'s scratchpad directory, or a `mktemp -d` directory when the session lists none, never under `.gaia/local` or `.notebook`'
  assert_pinned "$RULE" 'so worktree isolation refuses the agent'"'"'s Write there.'
}
