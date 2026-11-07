#!/usr/bin/env bats
# Flow text lint: a working-document id in a flow's name or why fails the
# save-time lint (working_document_id), with where naming the flow and field.
# A placeholder id with no number stays clean.
#
# Fixtures are built in $BATS_TEST_TMPDIR with ids assembled at run time.
# Hermetic: no real specs, no telemetry.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
LINT="$REPO_ROOT/.gaia/scripts/spec/lint.sh"

SPEC_ID="SPEC-""001"
FLOW_ONE="FLOW-""001"

# make_spec <path> <name text> <why text> [why continuation line]
make_spec() {
  local output_path="$1" name_text="$2" why_text="$3" why_more="${4:-}"
  {
    printf '%s\n' '---'
    printf 'spec_id: %s\n' "$SPEC_ID"
    printf '%s\n' 'type: feature' 'status: in-progress' 'immutable: true' \
      'wiki_promote_default: yes' 'chain_trigger: gaia-plan' 'lineage: []' \
      'intent: |' '  A member signs in.' 'success_criteria:' '  - A member reaches the dashboard.' \
      'flows:'
    printf '  - flow_id: %s\n' "$FLOW_ONE"
    printf '    slug: sign-in\n    name: %s\n    why: %s\n' "$name_text" "$why_text"
    if [ -n "$why_more" ]; then printf '      %s\n' "$why_more"; fi
    printf '%s\n' '    covers: [app/pages/sign-in]' \
      'scope_boundaries:' '  always:' '    - Keep sessions private.' \
      'clarifications:' '  answered: []' '  pending: []' \
      'research_summary: |' '  None.' 'created: 2026-01-01' 'updated: 2026-01-01' '---' '' '# Sign in'
  } >"$output_path"
}

working_document_id_findings() {
  printf '%s' "$1" | jq -c '[.findings[] | select(.code == "working_document_id")]'
}

@test "a clean flow lints clean" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "A member signs in" "Breaking sign-in blocks every task."
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}

@test "a plan id in name fails the lint, naming the flow and the field" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "As in PLAN-""003, a member signs in" "Breaking sign-in blocks every task."
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  findings="$(working_document_id_findings "$output")"
  [ "$(printf '%s' "$findings" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$findings" | jq -r '.[0].where')" = "frontmatter.flows.$FLOW_ONE.name" ]
}

@test "a spec id on a why continuation line fails the lint" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "A member signs in" "Breaking sign-in blocks every task," "unlike the case in SPEC-""003."
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  findings="$(working_document_id_findings "$output")"
  [ "$(printf '%s' "$findings" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$findings" | jq -r '.[0].where')" = "frontmatter.flows.$FLOW_ONE.why" ]
}

@test "ids in both name and why fail the lint, one finding per field" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "Per SPEC-""012, a member signs in" "Plan PLAN-""004 needs it."
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  findings="$(working_document_id_findings "$output")"
  [ "$(printf '%s' "$findings" | jq -c '[.[].where]')" = "[\"frontmatter.flows.$FLOW_ONE.name\",\"frontmatter.flows.$FLOW_ONE.why\"]" ]
}

@test "a placeholder id with no number stays clean" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "Like any FLOW-NNN, a member signs in" "Breaking sign-in blocks every task."
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
}
