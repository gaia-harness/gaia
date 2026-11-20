#!/usr/bin/env bats
# lineage: frontmatter lint (invalid_lineage).
#
# Fixtures are built in $BATS_TEST_TMPDIR from the real SPEC template, so the
# lint runs against the shipped shape. Hermetic: no real specs, no telemetry.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
LINT="$REPO_ROOT/.gaia/scripts/spec/lint.sh"
TEMPLATE="$REPO_ROOT/.claude/skills/gaia/references/spec/spec-template.md"

# Filled SPEC from the template with the given frontmatter line(s) in place of
# the template's "lineage: []" line. No argument drops the key entirely.
make_spec() {
  local output_path="$1" replacement="${2-__DROP__}"
  if [ "$replacement" = "__DROP__" ]; then
    awk '/^spec_id:/ { sub(/SPEC-NNN/, "SPEC-001") } /flow_id:/ { sub(/FLOW-NNN/, (++flow_count == 1 ? "FLOW-001" : "FLOW-002")) } /^ *(- )?slug:/ { sub(/slug:.*/, "slug: flow-" ++slug_count) } /^ *(- )?covers:/ { sub(/covers:.*/, "covers: [app/pages]") } /^ *(- )?test_path:/ { sub(/test_path:.*/, "test_path: .gaia/tests/lib/example.bats") } { print }' "$TEMPLATE" | sed '/^lineage: \[\]$/d' >"$output_path"
  else
    local replacement_file="$BATS_TEST_TMPDIR/repl.txt"
    printf '%s\n' "$replacement" >"$replacement_file"
    awk '/^spec_id:/ { sub(/SPEC-NNN/, "SPEC-001") } /flow_id:/ { sub(/FLOW-NNN/, (++flow_count == 1 ? "FLOW-001" : "FLOW-002")) } /^ *(- )?slug:/ { sub(/slug:.*/, "slug: flow-" ++slug_count) } /^ *(- )?covers:/ { sub(/covers:.*/, "covers: [app/pages]") } /^ *(- )?test_path:/ { sub(/test_path:.*/, "test_path: .gaia/tests/lib/example.bats") } { print }' "$TEMPLATE" \
      | awk -v replacement_file_path="$replacement_file" '/^lineage: \[\]$/ { while ((getline replacement_line < replacement_file_path) > 0) print replacement_line; next } { print }' >"$output_path"
  fi
}

# _lint_case <label> [make_spec replacement]: names the case, writes the SPEC
# and runs lint; the caller asserts the result.
_lint_case() {
  echo "case: $1"
  shift
  make_spec "$BATS_TEST_TMPDIR/s.md" "$@"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
}

@test "valid or absent lineage lints clean without extra findings" {
  # make_spec swaps the template's lineage line; without it every case below
  # would lint the template's own line instead of the entry under test.
  grep -q '^lineage: \[\]$' "$TEMPLATE"

  _lint_case "filled template with lineage: [] lints clean" 'lineage: []'
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]

  echo "case: absent lineage key passes and adds no missing_field finding"
  make_spec "$BATS_TEST_TMPDIR/s.md"
  grep -q '^lineage:' "$BATS_TEST_TMPDIR/s.md" && return 1
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]

  echo "case: absent lineage key: missing_field findings equal those of a fixture with it"
  make_spec "$BATS_TEST_TMPDIR/with.md" 'lineage: []'
  make_spec "$BATS_TEST_TMPDIR/without.md"
  # Drop a required key from both so missing_field findings exist to compare.
  sed -i.bak '/^research_summary: |$/,/^  Group by dispatch/d' "$BATS_TEST_TMPDIR/with.md"
  sed -i.bak '/^research_summary: |$/,/^  Group by dispatch/d' "$BATS_TEST_TMPDIR/without.md"
  run bash "$LINT" "$BATS_TEST_TMPDIR/with.md"
  with_lineage_findings="$(printf '%s' "$output" | jq -c '[.findings[] | select(.code == "missing_field")]')"
  run bash "$LINT" "$BATS_TEST_TMPDIR/without.md"
  without_lineage_findings="$(printf '%s' "$output" | jq -c '[.findings[] | select(.code == "missing_field")]')"
  [ "$with_lineage_findings" = "$without_lineage_findings" ]
  [ "$(printf '%s' "$with_lineage_findings" | jq 'length')" -ge 1 ]
  printf '%s' "$with_lineage_findings" | grep -q 'lineage' && return 1

  _lint_case "positive: flow list of research, issue, init passes" \
    'lineage: [research:release-2.0.0-readiness, issue:200, init:cost-work]'
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]

  _lint_case "positive: block list of the same entries passes" 'lineage:
  - research:release-2.0.0-readiness
  - issue:200
  - init:cost-work'
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]

  _lint_case "positive: spec and plan parents pass" 'lineage: [spec:SPEC-086, plan:PLAN-091]'
  [ "$status" -eq 0 ]
}

@test "each invalid lineage entry is refused, and a lone bad entry yields one invalid_lineage naming it" {
  _lint_case "guard: one bad entry yields exactly one invalid_lineage naming it" \
    'lineage: [research:topic-a, bogus]'
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq '[.findings[] | select(.code == "invalid_lineage")] | length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq '.findings | length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.findings[0].where')" = "frontmatter.lineage" ]
  printf '%s' "$output" | jq -r '.findings[0].message' | grep -q 'bogus'

  _lint_case "guard: branch is not an allowed parent kind" 'lineage: [branch:fix/foo]'
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '[.findings[] | select(.code == "invalid_lineage")] | length == 1' >/dev/null

  local entry
  for entry in pr:12 session:abc command:run-1; do
    _lint_case "guard: the $entry kind is refused" "lineage: [$entry]"
    [ "$status" -eq 1 ]
  done

  _lint_case "guard: lowercase spec id is refused" 'lineage: [spec:spec-001]'
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '[.findings[] | select(.code == "invalid_lineage")] | length == 1' >/dev/null

  for entry in issue:0 issue:007 issue:abc; do
    _lint_case "guard: $entry (issue zero, leading zero or not a number) is refused" "lineage: [$entry]"
    [ "$status" -eq 1 ]
  done

  _lint_case "guard: block list with one bad entry is refused, naming only it" 'lineage:
  - research:topic-a
  - bogus-entry
  - issue:200'
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq '[.findings[] | select(.code == "invalid_lineage")] | length')" -eq 1 ]
  printf '%s' "$output" | jq -r '.findings[0].message' | grep -q 'bogus-entry'
}
