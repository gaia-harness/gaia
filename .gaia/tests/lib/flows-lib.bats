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

@test "parse refuses a SPEC that carries a uats key beside flows" {
  write_spec \
    'uats:' \
    '  - uat_id: UAT-001' \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]'

  run lib_call flows_lib_parse_spec "$SPEC"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -q 'uats' "$STDERR_FILE"
}

@test "parse refuses a SPEC that carries a uats key and no flows key" {
  write_spec \
    'uats:' \
    '  - uat_id: UAT-001'

  run lib_call flows_lib_parse_spec "$SPEC"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -q 'uats' "$STDERR_FILE"
}

@test "parse refuses a SPEC with no flows key" {
  write_spec 'summary: nothing here'

  run lib_call flows_lib_parse_spec "$SPEC"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -q 'flows' "$STDERR_FILE"
}

@test "parse refuses a SPEC with an empty flows list" {
  write_spec 'flows: []'

  run lib_call flows_lib_parse_spec "$SPEC"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -q 'flows' "$STDERR_FILE"
}

@test "validate reports uats_key_present for a uats key" {
  write_spec \
    'uats:' \
    '  - uat_id: UAT-001'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'uats_key_present'
}

@test "validate reports missing_flows for a SPEC with no flows key" {
  write_spec 'summary: nothing here'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'missing_flows'
}

@test "validate reports flow_missing_field with the field's location" {
  write_spec \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    covers: [app/pages/sign-in]'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'flow_missing_field'
  printf '%s\n' "$output" | grep -q "^flow_missing_field${TAB}.*${TAB}frontmatter.flows.FLOW-001.why\$"
}

@test "validate reports bad_flow_id for an id that is not FLOW and three digits" {
  write_spec \
    'flows:' \
    '  - flow_id: FLOW-1' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'bad_flow_id'
}

@test "validate reports duplicate_flow_id when two flows share an id" {
  write_spec \
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
    '    covers: [app/pages/sign-out]'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'duplicate_flow_id'
}

@test "validate reports bad_slug for a slug that is not kebab-case" {
  write_spec \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: Sign_In' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'bad_slug'
}

@test "validate reports flow_target_conflict when a flow has both covers and test_path" {
  write_spec \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]' \
    '    test_path: .gaia/tests/lib/sign-in.bats'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'flow_target_conflict'
}

@test "validate reports flow_target_conflict when a flow has neither covers nor test_path" {
  write_spec \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'flow_target_conflict'
}

@test "validate reports flow_target_conflict for an empty covers list" {
  write_spec \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: []'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'flow_target_conflict'
}

@test "validate reports given_when_then_field for a given key on a flow" {
  write_spec \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]' \
    '    given: a registered user'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'given_when_then_field'
}

@test "validate reports working_document_id for a SPEC id in a flow name" {
  write_spec \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in as SPEC-123 describes' \
    '    why: Sign in gates everything' \
    '    covers: [app/pages/sign-in]'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'working_document_id'
  printf '%s\n' "$output" | grep -q "^working_document_id${TAB}.*${TAB}frontmatter.flows.FLOW-001.name\$"
}

@test "validate reports working_document_id for a PLAN id in a flow why" {
  write_spec \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A user signs in' \
    '    why: Sign in gates everything in PLAN-45' \
    '    covers: [app/pages/sign-in]'

  run lib_call flows_lib_validate_spec "$SPEC"
  [ "$status" -eq 0 ]
  finding_codes | grep -qx 'working_document_id'
}

@test "covers reads a declaration on the first line" {
  printf '%s\n' \
    '// @covers app/pages/sign-in app/routes/drafts' \
    "import { test } from '@playwright/test';" >"$SPEC_FILE_UNDER_TEST"

  run lib_call flows_lib_covers_paths "$SPEC_FILE_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'app/pages/sign-in\napp/routes/drafts')" ]
}

@test "covers reads a declaration that follows a license comment" {
  printf '%s\n' \
    '/* Copyright Example' \
    ' * Licensed under the MIT license.' \
    ' */' \
    '' \
    '// @covers app/pages/sign-in' \
    "import { test } from '@playwright/test';" >"$SPEC_FILE_UNDER_TEST"

  run lib_call flows_lib_covers_paths "$SPEC_FILE_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ "$output" = 'app/pages/sign-in' ]
}

@test "covers reads every declaration line in file order" {
  printf '%s\n' \
    '// @covers app/pages/sign-in' \
    '// @covers app/routes/drafts app/services' \
    "import { test } from '@playwright/test';" >"$SPEC_FILE_UNDER_TEST"

  run lib_call flows_lib_covers_paths "$SPEC_FILE_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'app/pages/sign-in\napp/routes/drafts\napp/services')" ]
}

@test "covers ignores a declaration after the first import" {
  printf '%s\n' \
    "import { test } from '@playwright/test';" \
    '// @covers app/pages/sign-in' >"$SPEC_FILE_UNDER_TEST"

  run lib_call flows_lib_covers_paths "$SPEC_FILE_UNDER_TEST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -s "$STDERR_FILE" ]
}

@test "covers returns status 1 for a file with no declaration" {
  printf '%s\n' \
    '// A flow spec with no declaration.' \
    "import { test } from '@playwright/test';" >"$SPEC_FILE_UNDER_TEST"

  run lib_call flows_lib_covers_paths "$SPEC_FILE_UNDER_TEST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -s "$STDERR_FILE" ]
}

@test "the frontend package path and a subdirectory of it resolve against the real repository" {
  run lib_call flows_lib_web_package_path "$REPO_ROOT_REAL"
  [ "$status" -eq 0 ]
  [ "$output" = 'apps/web' ]

  run lib_call flows_lib_web_subdirectory "$REPO_ROOT_REAL" .playwright/flows
  [ "$status" -eq 0 ]
  [ "$output" = 'apps/web/.playwright/flows' ]
}
