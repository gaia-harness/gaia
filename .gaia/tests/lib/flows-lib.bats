#!/usr/bin/env bats
#
# The SPEC flows reader (flows-lib.sh): flows parse to one row each, a SPEC that
# carries a uats key, lacks flows, or has a malformed flow is refused with a
# reason, and a spec file's @covers paths are read from its leading comment
# block. Fixtures are written under $BATS_TEST_TMPDIR.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIB="$REPO_ROOT_REAL/.gaia/scripts/spec/flows-lib.sh"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  SPEC_FILE_UNDER_TEST="$BATS_TEST_TMPDIR/sample.spec.ts"
  STDERR_FILE="$BATS_TEST_TMPDIR/stderr"
  TAB=$'\t'
}

# Run one flows_lib_* function in a fresh shell with the library sourced.
# stderr goes to $STDERR_FILE so $output holds stdout only.
lib_call() {
  bash -c '. "$1" && shift && "$@"' _ "$LIB" "$@" 2>"$STDERR_FILE"
}

# write_spec <frontmatter-lines...>: a SPEC whose frontmatter holds the given
# lines, one per argument.
write_spec() {
  {
    printf -- '---\n'
    printf 'spec_id: SPEC-900\n'
    printf 'title: Sample\n'
    local line
    for line in "$@"; do
      printf '%s\n' "$line"
    done
    printf -- '---\n\n# Sample\n\nBody.\n'
  } >"$SPEC"
}

# The finding codes validate printed, one per line.
finding_codes() {
  printf '%s\n' "$output" | cut -f1
}

@test "a two-flow SPEC parses to one row per flow and validates with no findings" {
  write_spec \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in-and-save' \
    '    name: A returning user signs in and saves a draft' \
    '    why: Breaking it blocks the main task and risks losing data' \
    '    covers: [app/pages/sign-in, app/routes/drafts]' \
    '  - flow_id: FLOW-002' \
    '    slug: plan-check-refuses-a-uats-spec' \
    '    name: The plan check refuses a SPEC that still carries uats' \
    '    why: A silent pass would plan a SPEC no gate can check' \
    '    test_path: .gaia/tests/lib/plan-check-refuses-a-uats-spec.bats'

  run lib_call flows_lib_parse_spec "$SPEC"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "FLOW-001${TAB}sign-in-and-save${TAB}A returning user signs in and saves a draft${TAB}Breaking it blocks the main task and risks losing data${TAB}web${TAB}app/pages/sign-in app/routes/drafts" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "FLOW-002${TAB}plan-check-refuses-a-uats-spec${TAB}The plan check refuses a SPEC that still carries uats${TAB}A silent pass would plan a SPEC no gate can check${TAB}command${TAB}.gaia/tests/lib/plan-check-refuses-a-uats-spec.bats" ]

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# expect_parse_refusal <row> <word the reason names> <frontmatter-lines...>:
# the SPEC is refused with exit 2, no stdout and a reason naming the word.
expect_parse_refusal() {
  local row="$1" word="$2"
  shift 2
  write_spec "$@"
  run lib_call flows_lib_parse_spec "$SPEC"
  [ "$status" -eq 2 ] || { echo "row $row: status $status"; return 1; }
  [ -z "$output" ] || { echo "row $row: output: $output"; return 1; }
  grep -q "$word" "$STDERR_FILE" || { echo "row $row: reason does not name $word"; return 1; }
}

# expect_finding <row> <finding code> <frontmatter-lines...>: validate exits 0
# and prints the code.
expect_finding() {
  local row="$1" code="$2"
  shift 2
  write_spec "$@"
  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "row $row: status $status"; return 1; }
  finding_codes | grep -qx "$code" || { echo "row $row: no $code in: $output"; return 1; }
}

# expect_covers <row> <status> <expected output> <spec file lines...>
expect_covers() {
  local row="$1" expected_status="$2" expected_output="$3"
  shift 3
  printf '%s\n' "$@" >"$SPEC_FILE_UNDER_TEST"
  run lib_call flows_lib_covers_paths "$SPEC_FILE_UNDER_TEST"
  [ "$status" -eq "$expected_status" ] || { echo "row $row: status $status"; return 1; }
  [ "$output" = "$expected_output" ] || { echo "row $row: output: $output"; return 1; }
  [ "$expected_status" -eq 0 ] || [ ! -s "$STDERR_FILE" ] || { echo "row $row: stderr not empty"; return 1; }
}

@test "flows_lib_parse_spec refuses a SPEC with a uats key (beside or without flows), no flows key, or an empty flows list, exit 2 with a reason" {
  expect_parse_refusal uats-beside-flows uats \
    'uats:' \
    '  - uat_id: UAT-001' \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]' || return 1
  expect_parse_refusal uats-without-flows uats \
    'uats:' \
    '  - uat_id: UAT-001' || return 1
  expect_parse_refusal no-flows-key flows 'summary: nothing here' || return 1
  expect_parse_refusal empty-flows flows 'flows: []' || return 1
}

@test "flows_lib_validate_spec reports each finding code: uats_key_present, missing_flows, flow_missing_field, bad_flow_id, duplicate_flow_id, bad_slug, flow_target_conflict, given_when_then_field, working_document_id" {
  expect_finding uats-key uats_key_present \
    'uats:' \
    '  - uat_id: UAT-001' || return 1

  expect_finding no-flows-key missing_flows 'summary: nothing here' || return 1

  expect_finding missing-why flow_missing_field \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    covers: [app/pages/sign-in]' || return 1
  printf '%s\n' "$output" | grep -q "^flow_missing_field${TAB}.*${TAB}frontmatter.flows.FLOW-001.why\$" \
    || { echo "row missing-why: no location in: $output"; return 1; }

  expect_finding short-id bad_flow_id \
    'flows:' \
    '  - flow_id: FLOW-1' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]' || return 1

  expect_finding shared-id duplicate_flow_id \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-out' \
    '    name: A user signs out' \
    '    why: Sign out ends the session' \
    '    covers: [app/pages/sign-out]' || return 1

  expect_finding snake-case-slug bad_slug \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: Sign_In' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]' || return 1

  expect_finding covers-and-test-path flow_target_conflict \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]' \
    '    test_path: .gaia/tests/lib/sign-in.bats' || return 1

  expect_finding neither-target flow_target_conflict \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' || return 1

  expect_finding empty-covers flow_target_conflict \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: []' || return 1

  expect_finding given-key given_when_then_field \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]' \
    '    given: a registered user' || return 1

  expect_finding spec-id-in-name working_document_id \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in as SPEC-123 describes' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]' || return 1
  printf '%s\n' "$output" | grep -q "^working_document_id${TAB}.*${TAB}frontmatter.flows.FLOW-001.name\$" \
    || { echo "row spec-id-in-name: no location in: $output"; return 1; }

  expect_finding plan-id-in-why working_document_id \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything in PLAN-45' \
    '    covers: [app/pages/sign-in]' || return 1
}

@test "flows_lib_covers_paths reads @covers declarations from the leading comment block in file order, and ignores one after the first import or returns 1 with none" {
  expect_covers first-line 0 "$(printf 'app/pages/sign-in\napp/routes/drafts')" \
    '// @covers app/pages/sign-in app/routes/drafts' \
    "import { test } from '@playwright/test';" || return 1
  expect_covers after-license 0 'app/pages/sign-in' \
    '/* Copyright Example' \
    ' * Licensed under the MIT license.' \
    ' */' \
    '' \
    '// @covers app/pages/sign-in' \
    "import { test } from '@playwright/test';" || return 1
  expect_covers every-line-in-order 0 "$(printf 'app/pages/sign-in\napp/routes/drafts\napp/services')" \
    '// @covers app/pages/sign-in' \
    '// @covers app/routes/drafts app/services' \
    "import { test } from '@playwright/test';" || return 1
  expect_covers after-first-import 1 '' \
    "import { test } from '@playwright/test';" \
    '// @covers app/pages/sign-in' || return 1
  expect_covers no-declaration 1 '' \
    '// A flow spec with no declaration.' \
    "import { test } from '@playwright/test';" || return 1
}

@test "the frontend package path and a subdirectory of it resolve against the real repository" {
  run lib_call flows_lib_web_package_path "$REPO_ROOT_REAL"
  [ "$status" -eq 0 ]
  [ "$output" = 'apps/web' ]

  run lib_call flows_lib_web_subdirectory "$REPO_ROOT_REAL" .playwright/flows
  [ "$status" -eq 0 ]
  [ "$output" = 'apps/web/.playwright/flows' ]
}
