#!/usr/bin/env bats
#
# Doc-conformance suite for the flow-based gates of `/gaia-spec`: the playbook
# .claude/skills/gaia/references/spec.md proposes the feature's critical flows
# at gate 1, confirms them through AskUserQuestion with the recommended option
# first, caches the confirmed list in the gate-1 snapshot, prints every flow at
# gate 2, and self-checks flows in auto mode.
#
# DOC_SPEC_FLOWS_ROOT points the suite at a scratch copy of the repo; the
# recommended-set and snapshot pins have red twins that delete the pinned
# phrase from a copy and prove the check fails on it.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  FLOWS_ROOT="${DOC_SPEC_FLOWS_ROOT:-$REPO_ROOT}"
  SPEC_MD='.claude/skills/gaia/references/spec.md'
}

# pinned <file> <needle>: succeeds when the file holds the needle verbatim.
pinned() {
  grep -qF -- "$2" "$1"
}

# without_phrase <needle>: copies spec.md into the test tmpdir with every line
# holding the needle removed and prints the copy's path.
without_phrase() {
  local copy="$BATS_TEST_TMPDIR/spec-copy.md"
  grep -vF -- "$1" "$FLOWS_ROOT/$SPEC_MD" >"$copy" || true
  printf '%s\n' "$copy"
}

# Backticks in the needles are literal markdown, not command substitution.
NEEDLE_PROPOSE='the proposed critical flows, one line each'
NEEDLE_RECOMMENDED='the recommended set marked `(recommended)`'
NEEDLE_GATE1_ASK='Confirm the flows with `AskUserQuestion` (header `Gate 1`), `Looks right (Recommended)` first'
NEEDLE_SNAPSHOT="the confirmed flow list (each flow's \`flow_id\`, \`slug\`, \`name\`, \`why\`, and \`covers\` or \`test_path\`)"
NEEDLE_GATE2_PRINT='**Flows:** every flow in the draft, one line each, with its covered folders or test path'
NEEDLE_GATE2_ASK='Then one `AskUserQuestion` (header `Gate 2`, single-select), question `Save this SPEC as rendered?`, with two options:'
NEEDLE_GATE2_FIRST='- `Looks right (Recommended)`: save the SPEC as rendered.'
NEEDLE_AUTO='(b) every flow has an id, slug, name, why, and exactly one of covers or test path'

@test "gate 1 proposes the critical flows, one line each" {
  pinned "$FLOWS_ROOT/$SPEC_MD" "$NEEDLE_PROPOSE"
}

@test "gate 1 marks a recommended set" {
  pinned "$FLOWS_ROOT/$SPEC_MD" "$NEEDLE_RECOMMENDED"
}

@test "red twin: recommended-set pin fails on a copy without the phrase" {
  local copy
  copy="$(without_phrase "$NEEDLE_RECOMMENDED")"
  pinned "$copy" "$NEEDLE_RECOMMENDED" && return 1
  true
}

@test "gate 1 confirms the flows through AskUserQuestion with the recommended option first" {
  pinned "$FLOWS_ROOT/$SPEC_MD" "$NEEDLE_GATE1_ASK"
}

@test "the gate-1 snapshot caches the confirmed flow list" {
  pinned "$FLOWS_ROOT/$SPEC_MD" "$NEEDLE_SNAPSHOT"
}

@test "red twin: snapshot pin fails on a copy without the phrase" {
  local copy
  copy="$(without_phrase "$NEEDLE_SNAPSHOT")"
  pinned "$copy" "$NEEDLE_SNAPSHOT" && return 1
  true
}

@test "gate 2 prints every flow" {
  pinned "$FLOWS_ROOT/$SPEC_MD" "$NEEDLE_GATE2_PRINT"
}

@test "gate 2 confirms through its AskUserQuestion with the recommended option first" {
  pinned "$FLOWS_ROOT/$SPEC_MD" "$NEEDLE_GATE2_ASK"
  pinned "$FLOWS_ROOT/$SPEC_MD" "$NEEDLE_GATE2_FIRST"
}

@test "the auto-mode self-checks check flows" {
  pinned "$FLOWS_ROOT/$SPEC_MD" "$NEEDLE_AUTO"
}

@test "spec.md never mentions Given/When/Then" {
  grep -qF -- 'Given/When/Then' "$FLOWS_ROOT/$SPEC_MD" && return 1
  true
}

@test "spec.md never mentions UAT as a word" {
  grep -qE '\bUATs?\b' "$FLOWS_ROOT/$SPEC_MD" && return 1
  true
}
