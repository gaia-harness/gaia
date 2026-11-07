#!/usr/bin/env bats
# SPEC lint on flows: lint.sh accepts a filled flows template and refuses a
# SPEC with a uats: key, no flows: key, or a malformed flow, each by its finding
# code. Fixtures live in $BATS_TEST_TMPDIR. Ids are built at run time so this
# file carries no working-document id. Hermetic: no real specs, no telemetry.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
LINT="$REPO_ROOT/.gaia/scripts/spec/lint.sh"
TEMPLATE="$REPO_ROOT/.claude/skills/gaia/references/spec/spec-template.md"

SPEC_ID="SPEC-""001"
FLOW_ONE="FLOW-""001"
FLOW_TWO="FLOW-""002"

WEB_FLOW="  - flow_id: $FLOW_ONE
    slug: sign-in
    name: A member signs in
    why: Breaking sign-in blocks every main task.
    covers: [app/pages/sign-in]"

COMMAND_FLOW="  - flow_id: $FLOW_TWO
    slug: release-cut
    name: A maintainer cuts a release
    why: A bad release ships to every adopter.
    test_path: .gaia/tests/lib/release-cut.bats"

# make_spec <path> <flows block, "" for none> [status] [body] [extra frontmatter line]
make_spec() {
  local output_path="$1" flows_block="$2" status_value="${3:-in-progress}" body="${4:-}" extra="${5:-}"
  {
    printf '%s\n' '---'
    printf 'spec_id: %s\n' "$SPEC_ID"
    printf '%s\n' 'type: feature' "status: $status_value" 'immutable: true' \
      'wiki_promote_default: yes' 'chain_trigger: gaia-plan' 'lineage: []' \
      'intent: |' '  A member signs in.' 'success_criteria:' '  - A member reaches the dashboard.'
    if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
    if [ -n "$flows_block" ]; then printf 'flows:\n%s\n' "$flows_block"; fi
    printf '%s\n' 'scope_boundaries:' '  always:' '    - Keep sessions private.' \
      'clarifications:' '  answered: []' '  pending: []' \
      'research_summary: |' '  None.' 'created: 2026-01-01' 'updated: 2026-01-01' '---' '' '# Sign in' ''
    if [ -n "$body" ]; then printf '%s\n' "$body"; fi
  } >"$output_path"
}

lint_codes() {
  printf '%s' "$output" | jq -c '[.findings[].code]'
}

@test "the template filled by replacing its placeholders passes with a web and a command flow" {
  awk -v one="$FLOW_ONE" -v two="$FLOW_TWO" -v spec="$SPEC_ID" '
    /^spec_id:/ { sub(/SPEC-NNN/, spec) }
    /flow_id:/ { sub(/FLOW-NNN/, (++seen == 1 ? one : two)) }
    /^ *(- )?slug:/ { sub(/slug:.*/, "slug: " (++slugs == 1 ? "sign-in" : "release-cut")) }
    /^ *(- )?covers:/ { sub(/covers:.*/, "covers: [app/pages/sign-in]") }
    /^ *(- )?test_path:/ { sub(/test_path:.*/, "test_path: .gaia/tests/lib/release-cut.bats") }
    { print }
  ' "$TEMPLATE" >"$BATS_TEST_TMPDIR/s.md"
  grep -q '^flows:' "$BATS_TEST_TMPDIR/s.md"
  grep -q 'covers:' "$BATS_TEST_TMPDIR/s.md"
  grep -q 'test_path:' "$BATS_TEST_TMPDIR/s.md"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}

@test "a web flow and a command flow written directly pass" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$WEB_FLOW"$'\n'"$COMMAND_FLOW"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}

@test "a SPEC with a uats key fails uats_key_present" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$WEB_FLOW" in-progress '' 'uats: []'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["uats_key_present"]' ]
}

@test "a SPEC with no flows key fails missing_flows" {
  make_spec "$BATS_TEST_TMPDIR/s.md" ""
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.findings | map(.code) | index("missing_flows") != null'
}

@test "a flow missing flow_id fails flow_missing_field naming the field" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$(printf '%s\n' "$WEB_FLOW" | sed '/flow_id:/d;s/^    slug:/  - slug:/')"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.findings | map(select(.code == "flow_missing_field" and (.where | endswith(".flow_id")))) | length == 1'
}

@test "a flow missing slug fails flow_missing_field naming the field" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$(printf '%s\n' "$WEB_FLOW" | sed '/slug:/d')"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["flow_missing_field"]' ]
  [ "$(printf '%s' "$output" | jq -r '.findings[0].where')" = "frontmatter.flows.$FLOW_ONE.slug" ]
}

@test "a flow missing name fails flow_missing_field naming the field" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$(printf '%s\n' "$WEB_FLOW" | sed '/name:/d')"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["flow_missing_field"]' ]
  [ "$(printf '%s' "$output" | jq -r '.findings[0].where')" = "frontmatter.flows.$FLOW_ONE.name" ]
}

@test "a flow missing why fails flow_missing_field naming the field" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$(printf '%s\n' "$WEB_FLOW" | sed '/why:/d')"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["flow_missing_field"]' ]
  [ "$(printf '%s' "$output" | jq -r '.findings[0].where')" = "frontmatter.flows.$FLOW_ONE.why" ]
}

@test "a slug that is not kebab-case fails bad_slug" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$(printf '%s\n' "$WEB_FLOW" | sed 's/slug: sign-in/slug: Sign_In/')"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["bad_slug"]' ]
}

@test "a flow_id with the wrong prefix fails bad_flow_id" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$(printf '%s\n' "$WEB_FLOW" | sed "s/$FLOW_ONE/UAT-""001/")"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["bad_flow_id"]' ]
}

@test "two flows with one id fail duplicate_flow_id" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$WEB_FLOW"$'\n'"$(printf '%s\n' "$COMMAND_FLOW" | sed "s/$FLOW_TWO/$FLOW_ONE/")"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["duplicate_flow_id"]' ]
}

@test "a flow with a given field fails given_when_then_field" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$WEB_FLOW"$'\n    given: a signed-out member'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["given_when_then_field"]' ]
}

@test "a flow with both covers and test_path fails flow_target_conflict" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$WEB_FLOW"$'\n    test_path: .gaia/tests/lib/x.bats'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["flow_target_conflict"]' ]
}

@test "a flow with neither covers nor test_path fails flow_target_conflict" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$(printf '%s\n' "$WEB_FLOW" | sed '/covers:/d')"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["flow_target_conflict"]' ]
}

@test "a flow with an empty covers list fails flow_target_conflict" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$(printf '%s\n' "$WEB_FLOW" | sed 's/covers: .*/covers: []/')"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["flow_target_conflict"]' ]
}

@test "a flow name holding a plan id fails working_document_id" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$(printf '%s\n' "$WEB_FLOW" | sed "s/name: .*/name: As built in PLAN-""042/")"
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["working_document_id"]' ]
}

@test "a reopened SPEC without a reopen rationale still fails" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$WEB_FLOW" reopened
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(lint_codes)" = '["reopen_missing_rationale"]' ]
}

@test "a reopened SPEC with a reopen rationale and no UAT diff passes" {
  make_spec "$BATS_TEST_TMPDIR/s.md" "$WEB_FLOW" reopened '## Reopen rationale

The sign-in path changed.'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}
