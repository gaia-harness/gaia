#!/usr/bin/env bats
# Doc pins for where a dispatched agent's report file goes. In a linked
# worktree `.gaia/local` and `.notebook` are symlinks into the main checkout,
# so worktree isolation refuses an agent's Write there; the dispatch rule names
# the session scratchpad (or a `mktemp -d` directory) instead, and the one
# call site whose agent writes with the Write tool from a worktree run, the
# plan's UAT fidelity judge, keeps its verdict file out of the plan folder.
#
# Prose-to-prose only. Every presence check has a red twin: a scratch copy
# with the sentence removed must fail the same predicate.
#
# GAIA_SUBAGENT_DISPATCH_RULE and GAIA_SPEC_LIFECYCLE override the paths so a
# scratch copy can be driven through the same cases.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned sentences carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RULE="${GAIA_SUBAGENT_DISPATCH_RULE:-$ROOT/.claude/rules/subagent-dispatch.md}"
  LIFECYCLE="${GAIA_SPEC_LIFECYCLE:-$ROOT/.claude/skills/gaia/references/spec/lifecycle.md}"
}

# scratch_without <file> <literal>: a copy of <file> with every line carrying
# the literal removed; prints its path.
scratch_without() {
  local scratch_copy_path="$BATS_TEST_TMPDIR/without.md"
  grep -vF -- "$2" "$1" >"$scratch_copy_path"
  printf '%s\n' "$scratch_copy_path"
}

# assert_pinned <file> <literal>: present in the real file, absent from the
# scratch copy that drops it (the red twin).
assert_pinned() {
  grep -qF -- "$2" "$1" || { echo "missing in $1: $2" >&2; return 1; }
  local copy
  copy="$(scratch_without "$1" "$2")"
  grep -qF -- "$2" "$copy" && { echo "red twin did not fail: $2" >&2; return 1; }
  true
}

@test "the dispatch rule puts the report file in the scratchpad, never under .gaia/local or .notebook" {
  assert_pinned "$RULE" 'Put the file in the session'"'"'s scratchpad directory, or a `mktemp -d` directory when the session lists none, never under `.gaia/local` or `.notebook`'
  assert_pinned "$RULE" 'so worktree isolation refuses the agent'"'"'s Write there.'
}

@test "the UAT fidelity verdict file sits in the scratchpad, not in the plan folder" {
  assert_pinned "$LIFECYCLE" 'Take `<VERDICT_FILE>` as `uat-fidelity.json` in the session'"'"'s scratchpad directory, or in a `mktemp -d` directory when the session lists none, never under `<PLAN_DIR>`'
  assert_pinned "$LIFECYCLE" 'Verdict file: <VERDICT_FILE>'
  grep -nF -- '<PLAN_DIR>/uat-fidelity.json' "$LIFECYCLE" && return 1
  true
}
