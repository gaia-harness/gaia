#!/usr/bin/env bats
#
# Flow test: a review fix that drops a stated case without a verifiable SPEC
# destination is refused;
# the re-dispatched fixes file that quotes the edit and names where the dropped
# case still lives is accepted, and the post-fix SPEC lints. Drives the
# deterministic seams (drop-check.mjs, lint.sh) over one fixture, happy path
# only. Fixture ids are built at runtime from parts.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DROP_CHECK="$REPO_ROOT/.gaia/scripts/spec/drop-check.mjs"
  LINT="$REPO_ROOT/.gaia/scripts/spec/lint.sh"
  SPEC_ID="SPEC-""901"
  FLOW_ID="FLOW-""901"
  WORK="$BATS_TEST_TMPDIR/work"
  FINDINGS="$WORK/findings"
  PRE="$WORK/pre/SPEC.md"
  POST="$WORK/post/SPEC.md"
  FIXES="$FINDINGS/fixes.json"
  mkdir -p "$FINDINGS" "$WORK/pre" "$WORK/post"
}

# write_spec <path> <b1 case one> <b1 case two or empty> <notes line>
write_spec() {
  {
    printf '%s\n' '---'
    printf 'spec_id: %s\n' "$SPEC_ID"
    printf '%s\n' 'type: feature' 'status: in-progress' 'immutable: true' \
      'wiki_promote_default: yes' 'chain_trigger: gaia-plan' 'lineage: []' \
      'intent: |' '  A member manages the account.' 'success_criteria:' \
      '  - A member reaches the account page.' \
      'flows:' "  - flow_id: $FLOW_ID" '    slug: account' '    name: A member opens the account' \
      '    why: Breaking the account blocks every member.' '    covers: [app/pages/account]' \
      'scope_boundaries:' '  always:' '    - Keep sessions private.' \
      'clarifications:' '  answered: []' '  pending: []' \
      'research_summary: |' '  None.' 'created: 2026-01-01' 'updated: 2026-01-01' '---' '' \
      '# Account' '' '## Behaviors' '' \
      '- **B1** (refusal): A signed-out visitor is refused the account page.' \
      "  - Case: $2"
    [ -z "$3" ] || printf '  - Case: %s\n' "$3"
    printf '\n%s\n' '## Notes' '' "$4"
  } >"$1"
}

CASE_REWRITTEN_BEFORE="a signed-out visitor requests the account page -> redirected to sign-in."
CASE_REWRITTEN_AFTER="a signed-out visitor requests the account page -> the server answers 401 and shows sign-in."
CASE_DROPPED="a signed-out visitor requests the account export -> the server answers 401."
NOTES_LINE="Every signed-out request for the account export always gets the 401 answer."
DROP_FRAGMENT="signed-out request for the account export always gets"
UNVERIFIABLE_FRAGMENT="every signed-out export request is answered somewhere else entirely"
EDIT_QUOTE="a signed-out visitor requests the account page"
DROPPED_QUOTE="a signed-out visitor requests the account export"

write_fixes() { # edits-json fragment
  printf '{"fixes":[{"finding":"SEC-001","route":"spec","edits":%s,"drops":[{"behavior":"B1","case":"%s","destination":"still-stated","file":"SPEC.md","fragment":"%s"}]},{"finding":"TST-001","route":"rejected"}]}\n' \
    "$1" "$CASE_DROPPED" "$2" >"$FIXES"
}

check_drops() {
  run node "$DROP_CHECK" --fixes "$FIXES" --findings "$FINDINGS" --pre "$PRE" --post "$POST"
}

@test "a fix output refused for an untraced drop passes once each drop names its SPEC destination" {
  write_spec "$PRE" "$CASE_REWRITTEN_BEFORE" "$CASE_DROPPED" "$NOTES_LINE"
  write_spec "$POST" "$CASE_REWRITTEN_AFTER" "" "$NOTES_LINE"
  printf '{"findings":[{"id":"SEC-001"}]}\n' >"$FINDINGS/security.json"
  printf '{"findings":[{"id":"TST-001"}]}\n' >"$FINDINGS/tests.json"

  # First dispatch: every edit is quoted, but the dropped case names a
  # fragment that appears nowhere in the post-fix SPEC, so no destination
  # can be verified.
  EDITS="$(printf '[{"change":"edited","quote":"%s"},{"change":"dropped","quote":"%s"}]' "$EDIT_QUOTE" "$DROPPED_QUOTE")"
  write_fixes "$EDITS" "$UNVERIFIABLE_FRAGMENT"
  check_drops
  [ "$status" -eq 1 ]
  grep -qF -- "drop-check: SEC-001: B1 case" <<<"$output" || return 1
  grep -qF -- "fragment is not in SPEC.md: \"$UNVERIFIABLE_FRAGMENT\"" <<<"$output" || return 1
  [ "$(wc -l <<<"$output")" -eq 1 ]

  # Re-dispatch: the dropped case names a still-stated fragment that is in
  # the post-fix SPEC.
  write_fixes "$EDITS" "$DROP_FRAGMENT"
  check_drops
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run bash "$LINT" "$POST"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}
