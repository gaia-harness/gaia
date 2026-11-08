#!/usr/bin/env bats
#
# The flow-coverage check (flow-coverage.sh): every mechanical coverage gap of a
# SPEC's flows is one stdout finding naming the flow and the fault, a SPEC that
# carries uats or lacks flows is refused, and a fully covered SPEC prints
# nothing. Each case builds a scratch git repository under $BATS_TEST_TMPDIR
# holding copies of the scripts and libraries the check loads, a base commit and
# a branch commit, and passes --base and --listing, so no case runs Playwright.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRATCH="$BATS_TEST_TMPDIR/repo"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  LISTING="$BATS_TEST_TMPDIR/listing.json"
  STDERR_FILE="$BATS_TEST_TMPDIR/stderr"
  TESTS_OUT="$BATS_TEST_TMPDIR/flow-tests.tsv"
  FLOWS_DIRECTORY="apps/web/.playwright/flows"
  TAB=$'\t'
  build_scratch_repo
}

# Copy one real file into the scratch repo at its repo-relative path. A file the
# real tree lacks is skipped, so a missing script shows as a failed assertion.
copy_in() {
  local relative="$1"
  [ -f "$REPO_ROOT_REAL/$relative" ] || return 0
  mkdir -p "$SCRATCH/$(dirname "$relative")"
  cp "$REPO_ROOT_REAL/$relative" "$SCRATCH/$relative"
}

build_scratch_repo() {
  mkdir -p "$SCRATCH"
  git -C "$SCRATCH" init -q
  git -C "$SCRATCH" config user.email test@example.com
  git -C "$SCRATCH" config user.name test
  git -C "$SCRATCH" config commit.gpgsign false
  copy_in .gaia/scripts/spec/flows-lib.sh
  copy_in .gaia/scripts/spec/flow-coverage.sh
  copy_in .gaia/scripts/spec/working-doc-id-scan.sh
  copy_in .gaia/scripts/machine-local-ref-lib.sh
  copy_in .claude/hooks/lib/gaia-packages.sh
  copy_in .claude/hooks/lib/audit-base-provenance.sh
  mkdir -p "$SCRATCH/apps/web"
  printf '[{"name":"web","path":"apps/web"}]\n' >"$SCRATCH/.gaia/packages.json"
  printf '{"schemaVersion":1,"name":"web","stack":"web","globs":{"tddUnitTests":[],"tddStrictCandidates":[],"emergentTests":[],"preCommitSource":[],"doctorConfigs":[],"dependencyManifests":[]},"wiki":{"sourcePaths":[],"inventoryPaths":[],"flowPaths":[]}}\n' >"$SCRATCH/apps/web/gaia.package.json"
}

# add_file <repo-relative-path> <content...>: write the content, newline-joined.
add_file() {
  local relative="$1"
  shift
  mkdir -p "$SCRATCH/$(dirname "$relative")"
  printf '%s\n' "$@" >"$SCRATCH/$relative"
}

# add_spec_file <slug> <covers-path...>: a flow spec with one @covers line per
# path ahead of its code.
add_spec_file() {
  local slug="$1" lines=() declared
  shift
  for declared in "$@"; do
    lines+=("// @covers $declared")
  done
  lines+=("import { test } from '@playwright/test';" "test('$slug works', async () => {});")
  add_file "$FLOWS_DIRECTORY/$slug.spec.ts" "${lines[@]}"
}

# commit_all <message>: commit everything, return nothing.
commit_all() {
  git -C "$SCRATCH" add -A
  git -C "$SCRATCH" commit -q -m "$1"
}

# mark_base: commit the tree so far and remember it as the diff base.
mark_base() {
  commit_all base
  BASE=$(git -C "$SCRATCH" rev-parse HEAD)
}

# write_listing <slug...>: a playwright list document naming each spec file.
write_listing() {
  local slug entries=''
  for slug in "$@"; do
    entries="$entries${entries:+,}{\"title\":\"$slug.spec.ts\",\"file\":\"flows/$slug.spec.ts\",\"column\":0,\"line\":0,\"specs\":[],\"suites\":[]}"
  done
  printf '{"config":{"rootDir":"%s/apps/web/.playwright"},"suites":[%s],"errors":[]}\n' "$SCRATCH" "$entries" >"$LISTING"
}

# write_spec <flow-lines...>: a SPEC whose frontmatter is flows plus the lines.
write_spec() {
  {
    printf -- '---\n'
    printf 'spec_id: SPEC-900\n'
    printf 'title: Sample\n'
    printf '%s\n' "$@"
    printf -- '---\n\n# Sample\n'
  } >"$SPEC"
}

web_flow() {
  printf '%s\n' \
    "  - flow_id: $1" \
    "    slug: $2" \
    "    name: A user does the $2 thing" \
    '    why: Breaking it blocks the main task' \
    "    covers: [$3]"
}

command_flow() {
  printf '%s\n' \
    "  - flow_id: $1" \
    "    slug: $2" \
    "    name: The $2 check holds" \
    '    why: A silent pass would hide a regression' \
    "    test_path: $3"
}

# coverage [extra args...]: run the check against the scratch repo; stdout in
# $output, stderr in $STDERR_FILE.
coverage() {
  bash "$SCRATCH/.gaia/scripts/spec/flow-coverage.sh" \
    --spec "$SPEC" --root "$SCRATCH" --base "$BASE" --listing "$LISTING" "$@" \
    2>"$STDERR_FILE"
}

# The script under test must exist in the scratch repo: a run that can never
# start is a missing implementation, not a clean or refusing check.
script_exists() {
  [ -f "$SCRATCH/.gaia/scripts/spec/flow-coverage.sh" ]
}

@test "a web flow with no spec and a command flow with no file each exit 1 naming the flow and the path" {
  write_spec flows: \
    "$(web_flow FLOW-001 sign-in app/a)" \
    "$(command_flow FLOW-002 refuse-check .gaia/tests/lib/refuse-check.bats)"
  add_file apps/web/app/a/index.ts 'export {};'
  mark_base
  write_listing
  add_file apps/web/app/a/more.ts 'export {};'
  commit_all branch

  script_exists
  run coverage
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  printf '%s\n' "$output" | grep -qxF "flow-coverage: FLOW-001: missing $FLOWS_DIRECTORY/sign-in.spec.ts"
  printf '%s\n' "$output" | grep -qxF "flow-coverage: FLOW-002: missing .gaia/tests/lib/refuse-check.bats"
}

@test "a changed command flow test passes inside a run that reports only the web flow with no spec" {
  write_spec flows: \
    "$(web_flow FLOW-001 sign-in app/a)" \
    "$(command_flow FLOW-002 refuse-check .gaia/tests/lib/refuse-check.bats)"
  add_file apps/web/app/a/index.ts 'export {};'
  mark_base
  write_listing
  add_file .gaia/tests/lib/refuse-check.bats '@test "refuses" { true; }'
  commit_all branch

  script_exists
  run coverage
  [ "$status" -eq 1 ]
  [ "$output" = "flow-coverage: FLOW-001: missing $FLOWS_DIRECTORY/sign-in.spec.ts" ]
}

@test "a flow test untouched on the branch exits 1 while the same file extended on the branch passes" {
  write_spec flows: \
    "$(web_flow FLOW-001 untouched app/a)" \
    "$(web_flow FLOW-002 extended app/a)"
  add_file apps/web/app/a/index.ts 'export {};'
  add_spec_file untouched app/a
  add_spec_file extended app/a
  mark_base
  write_listing untouched extended
  add_file apps/web/app/a/more.ts 'export {};'
  printf '%s\n' "test('also works', async () => {});" >>"$SCRATCH/$FLOWS_DIRECTORY/extended.spec.ts"
  commit_all branch

  script_exists
  run coverage
  [ "$status" -eq 1 ]
  [ "$output" = "flow-coverage: FLOW-001: $FLOWS_DIRECTORY/untouched.spec.ts not changed on the branch" ]
}

@test "a changed web flow spec that the Playwright listing omits exits 1 as not collected" {
  write_spec flows: "$(web_flow FLOW-001 sign-in app/a)"
  add_file apps/web/app/a/index.ts 'export {};'
  mark_base
  write_listing
  add_file apps/web/app/a/more.ts 'export {};'
  add_spec_file sign-in app/a
  commit_all branch

  script_exists
  run coverage
  [ "$status" -eq 1 ]
  [ "$output" = "flow-coverage: $FLOWS_DIRECTORY/sign-in.spec.ts: not in the Playwright listing" ]
}

@test "a spec with no covers line and a spec whose covers path does not exist are both reported in one run" {
  write_spec flows: \
    "$(web_flow FLOW-001 no-declaration app/a)" \
    "$(web_flow FLOW-002 bad-declaration app/a)"
  add_file apps/web/app/a/index.ts 'export {};'
  mark_base
  write_listing no-declaration bad-declaration
  add_file "$FLOWS_DIRECTORY/no-declaration.spec.ts" "import { test } from '@playwright/test';" "test('x works', async () => {});"
  add_spec_file bad-declaration app/a app/ghost
  add_file apps/web/app/a/more.ts 'export {};'
  commit_all branch

  script_exists
  run coverage
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  printf '%s\n' "$output" | grep -qxF "flow-coverage: $FLOWS_DIRECTORY/no-declaration.spec.ts: no @covers declaration"
  printf '%s\n' "$output" | grep -qxF "flow-coverage: $FLOWS_DIRECTORY/bad-declaration.spec.ts: @covers path does not resolve: app/ghost"
}

@test "a spec that declares only one of two changed SPEC folders exits 1 naming the missed folder" {
  write_spec flows: "$(web_flow FLOW-001 sign-in 'app/a, app/b')"
  add_file apps/web/app/a/index.ts 'export {};'
  add_file apps/web/app/b/index.ts 'export {};'
  mark_base
  write_listing sign-in
  add_file apps/web/app/a/more.ts 'export {};'
  add_file apps/web/app/b/more.ts 'export {};'
  add_spec_file sign-in app/a
  commit_all branch

  script_exists
  run coverage
  [ "$status" -eq 1 ]
  [ "$output" = "flow-coverage: $FLOWS_DIRECTORY/sign-in.spec.ts: @covers misses app/b" ]
}

@test "a branch that changed only the declared SPEC folder passes though the SPEC lists a second folder" {
  write_spec flows: "$(web_flow FLOW-001 sign-in 'app/a, app/b')"
  add_file apps/web/app/a/index.ts 'export {};'
  add_file apps/web/app/b/index.ts 'export {};'
  mark_base
  write_listing sign-in
  add_file apps/web/app/a/more.ts 'export {};'
  add_spec_file sign-in app/a
  commit_all branch

  script_exists
  run coverage
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a declaration of app/home does not cover a changed app/homepage folder the SPEC lists" {
  write_spec flows: "$(web_flow FLOW-001 sign-in 'app/home, app/homepage')"
  add_file apps/web/app/home/index.ts 'export {};'
  add_file apps/web/app/homepage/index.ts 'export {};'
  mark_base
  write_listing sign-in
  add_file apps/web/app/homepage/more.ts 'export {};'
  add_spec_file sign-in app/home
  commit_all branch

  script_exists
  run coverage
  [ "$status" -eq 1 ]
  [ "$output" = "flow-coverage: $FLOWS_DIRECTORY/sign-in.spec.ts: @covers misses app/homepage" ]
}

@test "a flow test whose title holds a SPEC id exits 1 naming the file, the line and the match" {
  write_spec flows: "$(web_flow FLOW-001 sign-in app/a)"
  add_file apps/web/app/a/index.ts 'export {};'
  mark_base
  write_listing sign-in
  add_file apps/web/app/a/more.ts 'export {};'
  add_file "$FLOWS_DIRECTORY/sign-in.spec.ts" \
    '// @covers app/a' \
    "import { test } from '@playwright/test';" \
    "test('SPEC-123 sign in works', async () => {});"
  commit_all branch

  script_exists
  run coverage
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  case "$output" in
    "flow-coverage: "*"sign-in.spec.ts:3: working-doc id "*SPEC-123*) ;;
    *) return 1 ;;
  esac
}

@test "a SPEC with a uats key and no flows exits 2 with a reason and no clean result" {
  write_spec 'uats:' '  - uat_id: UAT-001'
  mark_base
  write_listing

  script_exists
  run coverage
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -q . "$STDERR_FILE"
}

@test "a SPEC with no flows key exits 2 with a reason and no clean result" {
  write_spec 'tags: [x]'
  mark_base
  write_listing

  script_exists
  run coverage
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -q . "$STDERR_FILE"
}

@test "flow-tests-out writes one row per existing flow test with its kind and path" {
  write_spec flows: \
    "$(web_flow FLOW-001 sign-in app/a)" \
    "$(command_flow FLOW-002 refuse-check .gaia/tests/lib/refuse-check.bats)" \
    "$(web_flow FLOW-003 not-written app/a)"
  add_file apps/web/app/a/index.ts 'export {};'
  mark_base
  write_listing sign-in
  add_file apps/web/app/a/more.ts 'export {};'
  add_spec_file sign-in app/a
  add_file .gaia/tests/lib/refuse-check.bats '@test "refuses" { true; }'
  commit_all branch

  script_exists
  run coverage --flow-tests-out "$TESTS_OUT"
  [ "$status" -eq 1 ]
  [ "$output" = "flow-coverage: FLOW-003: missing $FLOWS_DIRECTORY/not-written.spec.ts" ]
  [ "$(wc -l <"$TESTS_OUT" | tr -d ' ')" -eq 2 ]
  grep -qxF "FLOW-001${TAB}sign-in${TAB}web${TAB}$FLOWS_DIRECTORY/sign-in.spec.ts" "$TESTS_OUT"
  grep -qxF "FLOW-002${TAB}refuse-check${TAB}command${TAB}.gaia/tests/lib/refuse-check.bats" "$TESTS_OUT"
}

@test "a fully covered two-flow SPEC exits 0 and prints nothing" {
  write_spec flows: \
    "$(web_flow FLOW-001 sign-in app/a)" \
    "$(command_flow FLOW-002 refuse-check .gaia/tests/lib/refuse-check.bats)"
  add_file apps/web/app/a/index.ts 'export {};'
  mark_base
  write_listing sign-in
  add_file apps/web/app/a/more.ts 'export {};'
  add_spec_file sign-in app/a
  add_file .gaia/tests/lib/refuse-check.bats '@test "refuses" { true; }'
  commit_all branch

  script_exists
  run coverage
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the working-doc id scan given two file arguments scans both" {
  add_file first.spec.ts "test('SPEC-123 one', () => {});"
  add_file second.spec.ts 'const fine = 1;' "test('SPEC-456 two', () => {});"

  run bash "$SCRATCH/.gaia/scripts/spec/working-doc-id-scan.sh" "$SCRATCH/first.spec.ts" "$SCRATCH/second.spec.ts"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q "first.spec.ts:1: .*SPEC-123"
  printf '%s\n' "$output" | grep -q "second.spec.ts:2: .*SPEC-456"
}
