#!/usr/bin/env bats
#
# Doc-conformance suite: SPEC authoring guidance keeps case tables out of UATs.
# The self-review flags a case-enumerating UAT, the dispatch schema carries its
# kind, and the template tells the author to state a rule with one journey.
# Each assertion has a red twin run on a scratch copy.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SPEC_DIR="$REPO_ROOT/.claude/skills/gaia/references/spec"
  REVIEW="$SPEC_DIR/self-review.md"
  DISPATCH="$SPEC_DIR/self-review-dispatch.md"
  TEMPLATE="$SPEC_DIR/spec-template.md"
}

# Text of the case-enumeration section of a self-review file.
case_section() {
  awk '/^### 5\. Case-enumerating UATs$/{on=1;next} /^### /{on=0} on' "$1"
}

# 0 when the self-review file carries the heading, report key, trigger and exemption.
review_ok() {
  local file="$1" section
  grep -qxF '### 5. Case-enumerating UATs' "$file" || return 1
  grep -qF 'case_enumerating_uats: <N>: UAT-NNN: <phrasing>' "$file" || return 1
  section="$(case_section "$file")"
  grep -qF 'user-visible behavior' <<<"$section" || return 1
  grep -qF 'harness, script or doc behavior' <<<"$section" || return 1
}

dispatch_ok() {
  grep -qF '"case_enumeration"' "$1"
}

template_ok() {
  local flat
  flat="$(tr '\n' ' ' <"$1" | tr -s ' ')"
  grep -qF 'states a rule with one representative journey' <<<"$flat" || return 1
  grep -qF 'case tables belong to the lowest layer' <<<"$flat" || return 1
}

@test "self-review carries the case-enumeration section, key, trigger and exemption" {
  run review_ok "$REVIEW"
  [ "$status" -eq 0 ]
}

@test "self-review check fails on a copy without the exemption" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  grep -vF 'harness, script or doc behavior' "$REVIEW" >"$scratch"
  run review_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "self-review check fails on a copy without the report key" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  grep -vF 'case_enumerating_uats:' "$REVIEW" >"$scratch"
  run review_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "self-review keeps the pending clarifications section after the new one" {
  run grep -qxF '### 6. Pending clarifications' "$REVIEW"
  [ "$status" -eq 0 ]
}

@test "dispatch lists the case_enumeration kind" {
  run dispatch_ok "$DISPATCH"
  [ "$status" -eq 0 ]
}

@test "dispatch check fails on a copy without the kind" {
  scratch="$BATS_TEST_TMPDIR/dispatch.md"
  sed 's/"case_enumeration" | //' "$DISPATCH" >"$scratch"
  run dispatch_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "template tells the author to state a rule with one journey and leave case tables low" {
  run template_ok "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "template no longer names Playwright in the then comment" {
  run grep -qF 'write a Playwright' "$TEMPLATE"
  [ "$status" -ne 0 ]
}

@test "template check fails on a copy without the layering sentence" {
  scratch="$BATS_TEST_TMPDIR/template.md"
  sed 's/case tables belong to the lowest layer/nothing/' "$TEMPLATE" >"$scratch"
  run template_ok "$scratch"
  [ "$status" -ne 0 ]
}
