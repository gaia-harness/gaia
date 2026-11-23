#!/usr/bin/env bats
#
# Pins the story-layer instructions of the security test writer
# (.claude/agents/security-test-writer.md).
#
# A plan can hand the writer an access, forgery or secrets test on a story. A
# kind bullet with no story-layer instruction leaves the writer to report the
# test `cannot_write`, which stops the plan's security-writer step. So: the
# Access and Secret bullets each say what a story test asserts, the Forgery
# bullet reports a story forgery test written only when the dispatch names a
# route or real-server sibling, and the entry-point line names the story's
# entry point.
#
# Each check reads one line, found by its own prefix, so a phrase surviving on
# another line cannot green a line that dropped it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WRITER_AGENT="$REPO_ROOT/.claude/agents/security-test-writer.md"
}

# line_with_prefix <file> <literal prefix>
# Prints the one line starting with the prefix; fails unless exactly one does.
line_with_prefix() {
  local file="$1" prefix="$2" matches
  matches="$(awk -v prefix="$prefix" 'index($0, prefix) == 1' "$file")"
  [ -n "$matches" ] || { echo "no line starts with: $prefix" >&2; return 1; }
  [ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" = 1 ] || { echo "more than one line starts with: $prefix" >&2; return 1; }
  printf '%s\n' "$matches"
}

# line_carries <file> <literal prefix> <literal needle>
line_carries() {
  local line
  line="$(line_with_prefix "$1" "$2")" || return 1
  grep -qF -- "$3" <<<"$line" || { echo "line starting '$2' lacks: $3" >&2; return 1; }
}

ACCESS_STORY="For a test on a story, assert the forbidden control or data is absent from the story's rendered output for the refused actor's props."
SECRET_STORY="For a test on a story, assert the value is absent from the story's rendered output while it is present in the story's props."
FORGERY_STORY='with a `Sibling:` line, edit it to assert the field is no longer rendered and report it `written`; without one, edit nothing and report it `cannot_write`'
STORY_ENTRY_POINT='a story test is a `.test()` on the story that renders the behavior'"'"'s state'

@test "the Access bullet tells the writer what an access row on a story test asserts" {
  line_carries "$WRITER_AGENT" '- Access:' "$ACCESS_STORY"
}

@test "the Secret bullet covers any row on a story test, not only a change row" {
  line_carries "$WRITER_AGENT" '- Secret:' "$SECRET_STORY"
}

@test "the Forgery bullet makes a story forgery row written only beside a route or real-server sibling" {
  line_carries "$WRITER_AGENT" '- Forgery:' "$FORGERY_STORY"
}

@test "the entry-point line names a story test's entry point" {
  line_carries "$WRITER_AGENT" "Use the layer's real entry point:" "$STORY_ENTRY_POINT"
}
