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

@test "lint refuses a missing, empty, fenced or malformed behaviors section by finding code" {
  echo "case: a SPEC with no behaviors section"
  make_spec "$BATS_TEST_TMPDIR/SPEC.md" 'Nothing else.'
  run bash "$LINT" "$BATS_TEST_TMPDIR/SPEC.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["missing_behaviors"]' ]

  echo "case: a Behaviors heading with no behaviors"
  make_spec "$BATS_TEST_TMPDIR/SPEC.md" '## Behaviors

Nothing yet.'
  run bash "$LINT" "$BATS_TEST_TMPDIR/SPEC.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["missing_behaviors"]' ]

  echo "case: a Behaviors heading only inside a code fence"
  make_spec "$BATS_TEST_TMPDIR/SPEC.md" '```
## Behaviors

- **B1** (access): Fenced example.
  - Case: a -> b.
```'
  run bash "$LINT" "$BATS_TEST_TMPDIR/SPEC.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["missing_behaviors"]' ]

  echo "case: a behavior with no id, a duplicate id, an unknown kind or no case"
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

@test "a clarifications.deferred list between answered and pending is not part of the last answer" {
  make_spec "$BATS_TEST_TMPDIR/SPEC.md" "$GOOD_BEHAVIORS" 'Use the hosted provider.'
  sed 's/^  pending: \[\]$/  deferred:\n    - "Deferred: export limit undecided"\n  pending: []/' \
    "$BATS_TEST_TMPDIR/SPEC.md" >"$BATS_TEST_TMPDIR/SPEC.deferred.md"
  grep -qF 'deferred:' "$BATS_TEST_TMPDIR/SPEC.deferred.md" || return 1
  mv "$BATS_TEST_TMPDIR/SPEC.deferred.md" "$BATS_TEST_TMPDIR/SPEC.md"
  printf '%s\n' '# Requirements' '' 'Use the hosted provider.' >"$BATS_TEST_TMPDIR/REQUIREMENTS.md"
  run bash "$LINT" "$BATS_TEST_TMPDIR/SPEC.md"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# The CLIs' entry guard compared an unresolved argv path with the module's
# realpath, so through a symlinked directory the main block never ran and the
# CLI printed nothing and exited 0.
@test "the spec scripts run through a symlinked directory" {
  ln -s "$REPO_ROOT/.gaia/scripts/spec" "$BATS_TEST_TMPDIR/linked"
  make_spec "$BATS_TEST_TMPDIR/SPEC.md" 'Nothing else.'

  echo "case: the behaviors CLI counts the behaviors"
  run node "$BATS_TEST_TMPDIR/linked/behaviors.mjs" --count "$BATS_TEST_TMPDIR/SPEC.md"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  echo "case: the drop-check CLI runs its main block"
  run node "$BATS_TEST_TMPDIR/linked/drop-check.mjs"
  [ "$status" -eq 2 ]
  [[ "$output" == *'drop-check:'* ]]

  echo "case: lint refuses a SPEC with no behaviors section"
  run bash "$BATS_TEST_TMPDIR/linked/lint.sh" "$BATS_TEST_TMPDIR/SPEC.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["missing_behaviors"]' ]
}
