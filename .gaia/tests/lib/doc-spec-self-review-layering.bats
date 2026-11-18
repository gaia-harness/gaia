#!/usr/bin/env bats
#
# Doc-conformance suite: SPEC authoring guidance keeps case tables out of
# flows. The template tells the author a flow names one critical path and
# leaves case tables low, and no longer names Playwright in the then comment.
# Each assertion has a red twin run on a scratch copy.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SPEC_DIR="$REPO_ROOT/.claude/skills/gaia/references/spec"
  TEMPLATE="$SPEC_DIR/spec-template.md"
}

template_ok() {
  local flat
  flat="$(tr '\n' ' ' <"$1" | tr -s ' ')"
  grep -qF 'names one critical user path' <<<"$flat" || return 1
  grep -qF 'case tables belong to one parameterized test' <<<"$flat" || return 1
}

@test "template tells the author a flow names one critical path and leaves case tables low" {
  run template_ok "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "template no longer names Playwright in the then comment" {
  run grep -qF 'write a Playwright' "$TEMPLATE"
  [ "$status" -ne 0 ]
}

@test "template check fails on a copy without the layering sentence" {
  scratch="$BATS_TEST_TMPDIR/template.md"
  sed 's/case tables belong to one parameterized test/nothing/' "$TEMPLATE" >"$scratch"
  run template_ok "$scratch"
  [ "$status" -ne 0 ]
}
