#!/usr/bin/env bats
#
# Doc-conformance suite: /gaia-spec runs as one explicit, script-driven
# workflow with no dependency on a spec-kit core install. The shipped SPEC
# template, filled in, passes the lint script directly.
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
