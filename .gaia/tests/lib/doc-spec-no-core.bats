#!/usr/bin/env bats
#
# Doc-conformance suite: the shipped SPEC template, filled in, passes the SPEC
# lint script.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPLATE="$REPO_ROOT/.claude/skills/gaia/references/spec/spec-template.md"
  LINT="$REPO_ROOT/.gaia/scripts/spec/lint.sh"
}

@test "a filled template lints clean" {
  filled="$BATS_TEST_TMPDIR/filled.md"
  awk '/^spec_id:/ { sub(/SPEC-NNN/, "SPEC-001") } /flow_id:/ { sub(/FLOW-NNN/, (++flow_count == 1 ? "FLOW-001" : "FLOW-002")) } /^ *(- )?slug:/ { sub(/slug:.*/, "slug: flow-" ++slug_count) } /^ *(- )?covers:/ { sub(/covers:.*/, "covers: [app/pages]") } /^ *(- )?test_path:/ { sub(/test_path:.*/, "test_path: .gaia/tests/lib/example.bats") } { print }' "$TEMPLATE" > "$filled"

  run bash "$LINT" "$filled"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}
