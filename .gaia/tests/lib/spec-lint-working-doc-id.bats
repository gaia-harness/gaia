#!/usr/bin/env bats
# UAT text lint: a working-document id in a UAT's given, when or then fails the
# save-time lint (working_document_id), the same rule the e2e render applies.
#
# Fixtures are built in $BATS_TEST_TMPDIR from the real SPEC template, so the
# lint runs against the shipped shape. Hermetic: no real specs, no telemetry.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
LINT="$REPO_ROOT/.gaia/scripts/spec/lint.sh"
TEMPLATE="$REPO_ROOT/.claude/skills/gaia/references/spec/spec-template.md"

# Filled SPEC from the template; the optional sed expression edits its UAT text.
make_spec() {
  local output_path="$1" uat_edit="${2:-}"
  sed 's/SPEC-NNN/SPEC-001/;s/UAT-NNN/UAT-001/' "$TEMPLATE" >"$output_path"
  if [ -n "$uat_edit" ]; then
    sed -i.bak "$uat_edit" "$output_path"
  fi
}

working_document_id_findings() {
  printf '%s' "$1" | jq -c '[.findings[] | select(.code == "working_document_id")]'
}

@test "the template's UAT fields are the lines the fixtures edit" {
  grep -q '^    given: <Initial state' "$TEMPLATE"
  grep -q '^      no hedging\. The verifier' "$TEMPLATE"
}

@test "filled template lints clean: its uat_id line is not UAT text" {
  make_spec "$BATS_TEST_TMPDIR/s.md"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}

@test "a UAT id in given fails the lint, naming the UAT and the field" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 's/^    given: <Initial state/    given: <As in UAT-003, initial state/'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  findings="$(working_document_id_findings "$output")"
  [ "$(printf '%s' "$findings" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$findings" | jq -r '.[0].where')" = "frontmatter.uats.UAT-001.given" ]
}

@test "an id on a then continuation line fails the lint" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 's/^      no hedging\. The verifier/      no hedging, unlike the wrong-password case in UAT-003. The verifier/'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  findings="$(working_document_id_findings "$output")"
  [ "$(printf '%s' "$findings" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$findings" | jq -r '.[0].where')" = "frontmatter.uats.UAT-001.then" ]
}

@test "SPEC and PLAN ids in any case fail the lint, one finding per field" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 's/^    given: <Initial state/    given: <Per spec-12, initial state/;s/^    when: <Action/    when: <Plan-4 action/'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  findings="$(working_document_id_findings "$output")"
  [ "$(printf '%s' "$findings" | jq -c '[.[].where]')" = '["frontmatter.uats.UAT-001.given","frontmatter.uats.UAT-001.when"]' ]
}

@test "a placeholder id with no number stays clean" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 's/^    given: <Initial state/    given: <Like any UAT-NNN, initial state/'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
}
