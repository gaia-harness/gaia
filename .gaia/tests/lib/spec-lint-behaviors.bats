#!/usr/bin/env bats
# SPEC lint on the behaviors section and the requirements file: lint.sh refuses
# a malformed behavior and a SPEC whose answered clarification the sibling
# requirements file lacks, each by its finding code. Fixtures live in
# $BATS_TEST_TMPDIR. Hermetic: no real specs, no telemetry.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
LINT="$REPO_ROOT/.gaia/scripts/spec/lint.sh"

SPEC_ID="SPEC-""001"
FLOW_ID="FLOW-""001"

GOOD_BEHAVIORS='## Behaviors

- **B1** (access): A signed-out visitor cannot open the dashboard.
  - Case: signed-out visitor requests the dashboard -> redirected to sign-in.'

# make_spec <path> <body> [answer text]
make_spec() {
  local output_path="$1" body="$2" answer="${3:-}"
  {
    printf '%s\n' '---'
    printf 'spec_id: %s\n' "$SPEC_ID"
    printf '%s\n' 'type: feature' 'status: in-progress' 'immutable: true' \
      'wiki_promote_default: yes' 'chain_trigger: gaia-plan' 'lineage: []' \
      'intent: |' '  A member signs in.' 'success_criteria:' '  - A member reaches the dashboard.' \
      'flows:' "  - flow_id: $FLOW_ID" '    slug: sign-in' '    name: A member signs in' \
      '    why: Breaking sign-in blocks every main task.' '    covers: [app/pages/sign-in]' \
      'scope_boundaries:' '  always:' '    - Keep sessions private.' 'clarifications:'
    if [ -n "$answer" ]; then
      printf '%s\n' '  answered:' '    - q: Which provider?' "      a: $answer" '  pending: []'
    else
      printf '%s\n' '  answered: []' '  pending: []'
    fi
    printf '%s\n' 'research_summary: |' '  None.' 'created: 2026-01-01' 'updated: 2026-01-01' '---' '' '# Sign in' ''
    printf '%s\n' "$body"
  } >"$output_path"
}

lint_codes() {
  printf '%s' "$output" | jq -c '[.findings[].code] | unique'
}

@test "a SPEC with a well-formed behaviors section passes" {
  make_spec "$BATS_TEST_TMPDIR/SPEC.md" "$GOOD_BEHAVIORS"
  run bash "$LINT" "$BATS_TEST_TMPDIR/SPEC.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}

@test "lint refuses a SPEC with no behaviors section" {
  make_spec "$BATS_TEST_TMPDIR/SPEC.md" 'Nothing else.'
  run bash "$LINT" "$BATS_TEST_TMPDIR/SPEC.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["missing_behaviors"]' ]
}

@test "lint refuses a behavior with no id, a duplicate id, an unknown kind or no case" {
  local body
  body='## Behaviors

- A behavior with no id.
  - Case: anyone -> something.
- **B1** (access): First.
  - Case: a -> b.
- **B1** (refusal): Duplicate id.
  - Case: a -> b.
- **B2** (mystery): Unknown kind.
  - Case: a -> b.
- **B3** (other): No case.'
  make_spec "$BATS_TEST_TMPDIR/SPEC.md" "$body"
  run bash "$LINT" "$BATS_TEST_TMPDIR/SPEC.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["invalid_behavior"]' ]
  [ "$(printf '%s' "$output" | jq '.findings | length')" -eq 5 ]
  [[ "$output" == *'malformed behavior line'* ]]
  [[ "$output" == *'duplicate id B1'* ]]
  [[ "$output" == *'unknown kind'* ]]
  [[ "$output" == *'B3 has no case'* ]]
}

@test "lint refuses an answered clarification the requirements file lacks" {
  make_spec "$BATS_TEST_TMPDIR/SPEC.md" "$GOOD_BEHAVIORS" 'Use the hosted provider.'
  printf '%s\n' '# Requirements' '' '## Clarify' '' '### Q1. Which provider?' '' 'Use   the self-hosted one.' \
    >"$BATS_TEST_TMPDIR/REQUIREMENTS.md"
  run bash "$LINT" "$BATS_TEST_TMPDIR/SPEC.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["answer_not_in_requirements"]' ]
  [[ "$output" == *'answered[0]'* ]]

  # The same answer present, after whitespace normalization, passes.
  printf '%s\n' '# Requirements' '' 'Use   the hosted' 'provider.' >"$BATS_TEST_TMPDIR/REQUIREMENTS.md"
  run bash "$LINT" "$BATS_TEST_TMPDIR/SPEC.md"
  [ "$status" -eq 0 ]
}
