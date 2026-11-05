#!/usr/bin/env bats
#
# Doc-conformance suite: SPEC authoring guidance keeps case tables out of UATs.
# The self-review flags a case-enumerating UAT and several sibling UATs that
# differ only in the transition they exercise (with the fold as the suggested
# fix, scoped to browser capabilities and pointing at the planner ladder, and
# its report line), flags an access refusal mixed into a browser journey, never
# recommends a route-surface UAT per rule, the dispatch schema carries every
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

# 0 when section 5 holds the sibling-transition trigger and the fold recommendation,
# and the file holds the report line.
sibling_ok() {
  local file="$1" section
  section="$(case_section "$file")"
  grep -qF 'several UATs that walk one user flow and differ only in which transition they exercise' <<<"$section" || return 1
  grep -qF 'one browser journey UAT for the flow' <<<"$section" || return 1
  grep -qF 'its own UAT routed by the ladder' <<<"$section" || return 1
  grep -qF '.claude/skills/gaia/references/plan/planner.md' <<<"$section" || return 1
  grep -qF 'are not flagged' <<<"$section" || return 1
  grep -qF 'sibling_transition_uats: <N>: UAT-NNN, UAT-NNN: <flow>' "$file" || return 1
}

# 0 when the file carries no route-surface-per-rule recommendation.
fold_absence_ok() {
  grep -qF 'route-surface UAT per transition rule' "$1" && return 1
  grep -qF 'route test per rule' "$1" && return 1
  return 0
}

# 0 when section 5 states the sibling_fold suggested fix is the fold.
fold_suggested_ok() {
  grep -qF "A \`sibling_fold\` finding's \`suggested_fix\` is the fold" "$1"
}

fold_dispatch_ok() {
  grep -qF "A \`sibling_fold\` finding's \`suggested_fix\` is always the fold" "$1"
}

refusal_ok() {
  local section
  section="$(case_section "$1")"
  grep -qF 'A `refusal_split` finding' <<<"$section" || return 1
  grep -qF 'splits the refusal into its own UAT' <<<"$section" || return 1
  grep -qF 'access_refusal_in_journey: <N>: UAT-NNN: <refusal>' "$1" || return 1
}

sibling_dispatch_ok() {
  grep -qF '"sibling_fold"' "$1"
}

template_ok() {
  local flat
  flat="$(tr '\n' ' ' <"$1" | tr -s ' ')"
  grep -qF 'states a rule with one representative journey' <<<"$flat" || return 1
  grep -qF 'case tables belong to one parameterized test' <<<"$flat" || return 1
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
  sed 's/case tables belong to one parameterized test/nothing/' "$TEMPLATE" >"$scratch"
  run template_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "self-review section 5 flags sibling transition UATs and recommends the fold" {
  run sibling_ok "$REVIEW"
  [ "$status" -eq 0 ]
}

@test "sibling check fails on a copy without the check paragraph" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  grep -vF 'several UATs that walk one user flow' "$REVIEW" >"$scratch"
  run sibling_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "sibling check fails on a copy without the trigger phrase" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  sed 's/differ only in which transition they exercise/differ/' "$REVIEW" >"$scratch"
  run sibling_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "sibling check fails on a copy without the recommended fold" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  sed 's/one browser journey UAT for the flow/merge them/' "$REVIEW" >"$scratch"
  run sibling_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "sibling check fails on a copy without the report line" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  grep -vF 'sibling_transition_uats:' "$REVIEW" >"$scratch"
  run sibling_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "dispatch lists the sibling_fold kind" {
  run sibling_dispatch_ok "$DISPATCH"
  [ "$status" -eq 0 ]
}

@test "sibling dispatch check fails on a copy without the kind" {
  scratch="$BATS_TEST_TMPDIR/dispatch.md"
  sed 's/"sibling_fold" | //' "$DISPATCH" >"$scratch"
  run sibling_dispatch_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "sibling check fails on a copy without the ladder pointer" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  sed 's#references/plan/planner.md#references/plan/other.md#' "$REVIEW" >"$scratch"
  run sibling_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "sibling check fails on a copy that flags siblings with no browser capability" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  sed 's/are not flagged/are flagged/' "$REVIEW" >"$scratch"
  run sibling_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "sibling check fails on a copy without the routed-by-the-ladder rule fold" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  sed 's/its own UAT routed by the ladder/its own UAT/' "$REVIEW" >"$scratch"
  run sibling_ok "$scratch"
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

@test "self-review and dispatch state the sibling fold is the suggested fix" {
  run fold_suggested_ok "$REVIEW"
  [ "$status" -eq 0 ]
  run fold_dispatch_ok "$DISPATCH"
  [ "$status" -eq 0 ]
}

@test "fold suggested-fix check fails on a self-review copy without the sentence" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  sed 's/suggested_fix` is the fold/suggested_fix` is a merge/' "$REVIEW" >"$scratch"
  run fold_suggested_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "fold suggested-fix check fails on a dispatch copy without the sentence" {
  scratch="$BATS_TEST_TMPDIR/dispatch.md"
  sed 's/suggested_fix` is always the fold/suggested_fix` is a merge/' "$DISPATCH" >"$scratch"
  run fold_dispatch_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "self-review carries the refusal split paragraph and report key" {
  run refusal_ok "$REVIEW"
  [ "$status" -eq 0 ]
}

@test "refusal check fails on a copy without the split suggestion" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  sed 's/splits the refusal into its own UAT/keeps it/' "$REVIEW" >"$scratch"
  run refusal_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "refusal check fails on a copy without the report key" {
  scratch="$BATS_TEST_TMPDIR/self-review.md"
  grep -vF 'access_refusal_in_journey:' "$REVIEW" >"$scratch"
  run refusal_ok "$scratch"
  [ "$status" -ne 0 ]
}

@test "dispatch lists the refusal_split kind" {
  run grep -qF '"refusal_split"' "$DISPATCH"
  [ "$status" -eq 0 ]
}

@test "refusal dispatch check fails on a copy without the kind" {
  scratch="$BATS_TEST_TMPDIR/dispatch.md"
  sed 's/"refusal_split" | //' "$DISPATCH" >"$scratch"
  run grep -qF '"refusal_split"' "$scratch"
  [ "$status" -ne 0 ]
}

@test "neither reference restates a capability token" {
  for token in 'client JavaScript' 'layout or visual position' 'focus or keyboard' 'rendered-DOM accessibility scan' 'browser-only navigation'; do
    grep -qF "$token" "$REVIEW" && return 1
    grep -qF "$token" "$DISPATCH" && return 1
  done
  true
}
