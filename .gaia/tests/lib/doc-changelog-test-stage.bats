#!/usr/bin/env bats
#
# Doc-conformance suite for CHANGELOG.md's `## [Unreleased]` section.
#
# The test table never shipped, so no Unreleased entry may name the table,
# its record, its marker, its checks or its merge gate.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CHANGELOG="${CHANGELOG_UNDER_TEST:-$REPO_ROOT/CHANGELOG.md}"
}

# unreleased <file>: the lines under `## [Unreleased]`, up to the next
# version heading.
unreleased() {
  awk '/^## \[Unreleased\]/ { in_section = 1; next } /^## \[/ { in_section = 0 } in_section' "$1"
}

# retired_terms: the test-table behavior names, one extended regex.
retired_terms() {
  printf '%s' 'tests\.json|test-design table|test design table|TEST-DESIGN|drift check|honesty checker|test-design merge gate|test-table|caseKinds|instructionKeys|coveredFlows'
}

@test "unreleased changelog names no retired test-table behavior" {
  [ -n "$(unreleased "$CHANGELOG")" ] || return 1
  found="$(unreleased "$CHANGELOG" | grep -n -i -E "$(retired_terms)" || true)"
  [ -z "$found" ] || return 1
}
