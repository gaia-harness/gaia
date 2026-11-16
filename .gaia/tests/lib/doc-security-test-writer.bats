#!/usr/bin/env bats
#
# Pins the story-layer instructions of the security test writer
# (.claude/agents/security-test-writer.md) and the plan audit's wrong-layer
# example that backs them (.claude/skills/gaia/references/plan/decomposition-audit.md).
#
# A plan can hand the writer an access, forgery or secrets row on a story test,
# since a change row whose source is a security requirement carries that
# requirement's kind whatever the existing test asserted. A kind bullet with no
# story-layer instruction leaves the writer to report the row `cannot_write`,
# which stops the plan's security-writer step. So: the Access and Secret
# bullets each say what a story row asserts, the Forgery bullet reports a story
# forgery row written only beside a route or real-server sibling, the
# entry-point line names the story's entry point, and the Test design lens
# flags a story security row with no such sibling, so the plan audit adds it
# before the writer sees it.
#
# Each check reads one line, found by its own prefix, so a phrase surviving on
# another line cannot green a line that dropped it. Each helper takes the file
# it reads so a scratch copy proves a check can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WRITER_AGENT="$REPO_ROOT/.claude/agents/security-test-writer.md"
  DECOMPOSITION_AUDIT="$REPO_ROOT/.claude/skills/gaia/references/plan/decomposition-audit.md"
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

ACCESS_STORY="For a row on a story test, assert the forbidden control or data is absent from the story's rendered output for the refused actor's props."
SECRET_STORY="For a row on a story test, assert the value is absent from the story's rendered output while it is present in the story's props."
FORGERY_STORY='report it `written` only when a route or real-server forgery row for the same requirement is among the rows you were given, otherwise `cannot_write`, naming that missing sibling row.'
STORY_ENTRY_POINT='a story test is a `.test()` on the story that renders the row'"'"'s state'
LENS_FORGERY_STORY='or a story row flagged forgery with no route or real-server row for the same requirement, whose refusal is a request outcome, or a story access or secrets row with no sibling route or real-server row'

@test "the Access bullet tells the writer what an access row on a story test asserts" {
  line_carries "$WRITER_AGENT" '- Access:' "$ACCESS_STORY"
}

@test "the Access check fails on a copy whose Access bullet lacks the story sentence" {
  local copy="$BATS_TEST_TMPDIR/security-test-writer.md"
  awk -v drop=" $ACCESS_STORY" '{ i = index($0, drop); if (i) $0 = substr($0, 1, i - 1) substr($0, i + length(drop)); print }' "$WRITER_AGENT" > "$copy"
  grep -qF -- "$ACCESS_STORY" "$copy" && return 1
  run line_carries "$copy" '- Access:' "$ACCESS_STORY"
  [ "$status" -ne 0 ]
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

@test "the Test design lens flags a story security row with no sibling route or real-server row" {
  line_carries "$DECOMPOSITION_AUDIT" '  - a wrong layer for what the row asserts,' "$LENS_FORGERY_STORY"
}
