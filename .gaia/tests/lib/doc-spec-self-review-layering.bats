#!/usr/bin/env bats
#
# Doc-conformance suite: SPEC authoring guidance keeps case tables out of
# flows. The self-review never recommends a route-surface test per rule, keeps
# its pending-clarifications section, restates no capability token, and the
# template tells the author a flow names one critical path and leaves case
# tables low. Each assertion has a red twin run on a scratch copy.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SPEC_DIR="$REPO_ROOT/.claude/skills/gaia/references/spec"
  REVIEW="$SPEC_DIR/self-review.md"
  DISPATCH="$SPEC_DIR/self-review-dispatch.md"
  TEMPLATE="$SPEC_DIR/spec-template.md"
}

# 0 when the file carries no route-surface-per-rule recommendation.
fold_absence_ok() {
  grep -qF 'route-surface UAT per transition rule' "$1" && return 1
  grep -qF 'route test per rule' "$1" && return 1
  return 0
}

template_ok() {
  local flat
  flat="$(tr '\n' ' ' <"$1" | tr -s ' ')"
  grep -qF 'names one critical user path' <<<"$flat" || return 1
  grep -qF 'case tables belong to one parameterized test' <<<"$flat" || return 1
}

@test "self-review keeps the pending clarifications section after the new one" {
  run grep -qxF '### 6. Pending clarifications' "$REVIEW"
  [ "$status" -eq 0 ]
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

@test "self-review no longer recommends a route-surface UAT per rule" {
  run fold_absence_ok "$REVIEW"
  [ "$status" -eq 0 ]
  run fold_absence_ok "$DISPATCH"
  [ "$status" -eq 0 ]
}

@test "absence check fails on a copy that restores the route-surface UAT per rule" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  cp "$REVIEW" "$scratch"
  printf '%s\n' 'one route-surface UAT per transition rule' >>"$scratch"
  run fold_absence_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "absence check fails on a copy that restores the route test per rule clause" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  cp "$REVIEW" "$scratch"
  printf '%s\n' 'one journey and a route test per rule prove the same contracts' >>"$scratch"
  run fold_absence_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "neither reference restates a capability token" {
  for token in 'client JavaScript' 'layout or visual position' 'focus or keyboard' 'rendered-DOM accessibility scan' 'browser-only navigation'; do
    grep -qF "$token" "$REVIEW" && return 1
    grep -qF "$token" "$DISPATCH" && return 1
  done
  true
}
