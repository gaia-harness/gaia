#!/usr/bin/env bats
#
# Flow test for the SPEC draft and review journey, driven through its
# deterministic seams (scripts, not the agent workflow): a brief and two
# answered questions sit in a requirements file, a pre-fix SPEC and a post-fix
# SPEC differ by one rewritten behavior line, two lens findings files and a
# fixes file account for it. The drop check accepts the fixes, lint passes the
# post-fix SPEC beside its requirements file, and spec-save saves it. Happy
# path only; refusals live in the suites that own each script.
#
# Fixture ids are built from parts so this file carries no id literal.
# Assertion style follows .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
HELPERS="$BATS_TEST_DIRNAME/helpers"

SPEC_ID="SPEC-""001"
FLOW_ID="FLOW-""001"

ANSWER_ONE="Use the hosted identity provider for every sign in"
ANSWER_TWO="Keep the session for thirty days on a trusted device"

OLD_CASE="a signed-out visitor requests the dashboard -> redirected to sign-in."
NEW_CASE="a signed-out visitor requests the dashboard -> redirected to the sign-in page with a return link."

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO" "${REPO}.git" "${REPO}-wt"
  fi
}

write_requirements() {
  cat >"$1" <<MD
# Requirements: $SPEC_ID

## Brief

A member signs in and reaches the dashboard.

## Clarify

### Q1. Which provider signs members in?

Answered by: the user

$ANSWER_ONE

### Q2. How long does a session last?

Answered by: the user

$ANSWER_TWO
MD
}

# write_spec <path> <case text>
write_spec() {
  {
    printf '%s\n' '---'
    printf 'spec_id: %s\n' "$SPEC_ID"
    printf '%s\n' 'type: feature' 'status: in-progress' 'immutable: true' \
      'wiki_promote_default: yes' 'chain_trigger: gaia-plan' 'lineage: []' \
      'intent: |' '  A member signs in.' 'success_criteria:' '  - A member reaches the dashboard.' \
      'flows:' "  - flow_id: $FLOW_ID" '    slug: sign-in' '    name: A member signs in' \
      '    why: Breaking sign-in blocks every main task.' '    covers: [app/pages/sign-in]' \
      'scope_boundaries:' '  always:' '    - Keep sessions private.' 'clarifications:' \
      '  answered:' \
      '    - q: Which provider signs members in?' "      a: $ANSWER_ONE" \
      '    - q: How long does a session last?' "      a: $ANSWER_TWO" \
      '  pending: []' \
      'research_summary: |' '  None.' 'created: 2026-01-01' 'updated: 2026-01-01' '---' '' \
      '# Sign in' '' '## Behaviors' '' \
      '- **B1** (access): A signed-out visitor cannot open the dashboard.' \
      "  - Case: $2"
  } >"$1"
}

@test "a brief and its answers become a saved SPEC whose review fixes pass the drop check" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec "$SPEC_ID" draft)"
  work="$BATS_TEST_TMPDIR/work"
  mkdir -p "$work/pre" "$work/post" "$work/findings"

  write_requirements "$work/REQUIREMENTS.md"
  write_spec "$work/pre/SPEC.md" "$OLD_CASE"
  write_spec "$work/post/SPEC.md" "$NEW_CASE"
  cp "$work/REQUIREMENTS.md" "$work/post/REQUIREMENTS.md"
  printf '{"findings":[{"id":"TST-001"}]}\n' >"$work/findings/tests.json"
  printf '{"findings":[{"id":"SEC-001"}]}\n' >"$work/findings/security.json"
  printf '%s\n' '{"fixes":[' \
    '{"finding":"TST-001","route":"spec","edits":[{"change":"edited","quote":"a signed-out visitor requests the dashboard -> redirected to sign-in."}],"drops":[]},' \
    '{"finding":"SEC-001","route":"rejected"}]}' >"$work/findings/fixes.json"

  # The drop check accepts the fixes.
  run node "$REPO_ROOT/.gaia/scripts/spec/drop-check.mjs" \
    --fixes "$work/findings/fixes.json" --findings "$work/findings" \
    --pre "$work/pre/SPEC.md" --post "$work/post/SPEC.md" \
    --requirements "$work/REQUIREMENTS.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Lint passes the post-fix SPEC beside its requirements file.
  run bash "$REPO_ROOT/.gaia/scripts/spec/lint.sh" "$work/post/SPEC.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]

  # spec-save saves it.
  cache="$REPO/.gaia/local/cache"
  mkdir -p "$cache"
  cp "$work/post/SPEC.md" "$cache/draft-$SPEC_ID.md"
  run bash "$REPO/.gaia/scripts/spec/spec-save.sh" "$REPO" "$SPEC_ID"
  [ "$status" -eq 0 ]
  saved="$REPO/.notebook/specs/$SPEC_ID/SPEC.md"
  [ "${lines[0]}" = "$saved" ]
  [ -f "$saved" ]
  grep -qF -- "$NEW_CASE" "$saved"
  [ ! -e "$cache/draft-$SPEC_ID.md" ]
  true
}
