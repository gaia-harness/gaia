#!/usr/bin/env bats
#
# The owning-phase UAT gate (uat-gate.sh), the contract divergence check
# (uat-divergence-check.sh) and the working-document id scan
# (working-doc-id-scan.sh). Shell level only: the gate's Playwright step runs
# through --report with committed JSON reports recorded from a real Playwright
# run (fixtures/uat-gate/), so no Node and no browser is needed. Rendered specs
# come from the real renderer (uat-write.sh), never a hand-written marker.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT_REAL/.gaia/scripts/spec"
  GATE="$SCRIPTS/uat-gate.sh"
  DIVERGENCE="$SCRIPTS/uat-divergence-check.sh"
  SCAN="$SCRIPTS/working-doc-id-scan.sh"
  WRITER="$SCRIPTS/uat-write.sh"
  REPORTS="$BATS_TEST_DIRNAME/fixtures/uat-gate"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/plan"
  . "$BATS_TEST_DIRNAME/../hooks/helpers/package-fixture.sh"
  write_builtin_descriptor "$WORK"
  SPEC="$WORK/SPEC.md"
  ROUTING="$WORK/plan/README.md"
  STDERR_FILE="$BATS_TEST_TMPDIR/stderr"
  FILE_PHASE_TWO_RELATIVE='apps/web/.playwright/e2e/checkout/guest-checkout-confirms-order.spec.ts'
  FILE_PHASE_THREE_RELATIVE='apps/web/.playwright/e2e/orders/order-history-lists-orders.spec.ts'
  FILE_PHASE_TWO="$WORK/$FILE_PHASE_TWO_RELATIVE"
  FILE_PHASE_THREE="$WORK/$FILE_PHASE_THREE_RELATIVE"
  ROUTE_FILE_RELATIVE='apps/web/app/route-tests/orders/tests/order-history-lists-orders.test.ts'
  ROUTE_FILE="$WORK/$ROUTE_FILE_RELATIVE"
  VITEST_REPORTS="$REPORTS/vitest"
}

# write_spec [<then-scalar>]: a SPEC with a non-UI UAT (phase 1) and two e2e
# UATs (phases 2 and 3), plus its routing table. The optional argument is the
# raw YAML scalar of the phase-2 then field.
write_spec() {
  cat >"$SPEC" <<SPEC_EOF
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: the pipeline is configured
    when: the script runs
    then: it exits zero
  - uat_id: UAT-002
    given: a visitor with items in the cart
    when: they check out as a guest
    then: ${1:-the confirmation page shows the order number}
  - uat_id: UAT-003
    given: a signed in member
    when: they open the order history
    then: every past order is listed newest first
---
SPEC_EOF
  cat >"$ROUTING" <<'ROUTING_EOF'
# Plan

<!-- gaia:uat-routing:start -->
| uat_id | surface | phase | feature_folder | file_name |
|---|---|---|---|---|
| UAT-001 | non-ui | 1 | - | - |
| UAT-002 | browser | 2 | checkout | guest-checkout-confirms-order.spec.ts |
| UAT-003 | browser | 3 | orders | order-history-lists-orders.spec.ts |
<!-- gaia:uat-routing:end -->
ROUTING_EOF
}

render_specs() {
  (cd "$WORK" && bash "$WRITER" "$SPEC" --routing "$ROUTING" >/dev/null)
}

# green_body <file> [<body>]: keep the marker and contract header through the
# import line, then replace the red body with a passing-looking one.
green_body() {
  local file="$1" body="${2:-}" header="$BATS_TEST_TMPDIR/header"
  sed -n '1,/^import /p' "$file" >"$header"
  if [ -z "$body" ]; then
    body="test('the confirmation page shows the order number', async ({page}) => {
  await page.goto('/checkout');
  await expect(page.getByRole('heading')).toBeVisible();
});"
  fi
  {
    cat "$header"
    printf '\n%s\n' "$body"
  } >"$file"
  rm -f "$header"
}

prepare_green() {
  write_spec
  render_specs
  green_body "$FILE_PHASE_TWO"
}

# gate <argument>...: run the gate from the fixture root; stdout lands in
# $output, stderr in $STDERR_FILE.
gate() {
  run bash -c "cd '$WORK' && bash '$GATE' '$SPEC' --routing '$ROUTING' $* 2>'$STDERR_FILE'"
}

# assert_stderr_names <needle>...: every needle appears in the captured stderr.
assert_stderr_names() {
  local needle
  for needle in "$@"; do
    grep -qF -- "$needle" "$STDERR_FILE" || return 1
  done
}

# --- Gate: the report statuses ---

@test "the committed report fixtures are the full set the status cases drive" {
  local expected="expected-failure failed fixme no-tests passed passed-two-files skipped" found report
  found=$(cd "$REPORTS" && ls ./*.json | sed 's#^\./##; s#\.json$##' | LC_ALL=C sort | tr '\n' ' ')
  [ "${found% }" = "$expected" ]
  # Every report is real Playwright JSON: it carries the reporter's own keys.
  for report in "$REPORTS"/*.json; do
    jq -e 'has("suites") and has("config") and has("stats")' "$report" >/dev/null
  done
}

@test "gate refuses an expected failure with the expected-failure reason" {
  prepare_green
  gate --phase 2 --report "$REPORTS/expected-failure.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" expected-failure
}

@test "gate refuses a skipped test with the skipped reason" {
  prepare_green
  gate --phase 2 --report "$REPORTS/skipped.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" skipped
}

@test "gate refuses a fixme test with the fixme reason" {
  prepare_green
  gate --phase 2 --report "$REPORTS/fixme.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" fixme
}

@test "gate refuses a failed test with the failed reason" {
  prepare_green
  gate --phase 2 --report "$REPORTS/failed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" failed
}

@test "gate refuses a report that holds no test for the file with the no-tests reason" {
  prepare_green
  gate --phase 2 --report "$REPORTS/no-tests.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" no-tests
}

@test "gate refuses a report that is not JSON, and a report that does not exist, as invalid input" {
  prepare_green
  printf 'not json\n' >"$BATS_TEST_TMPDIR/bad.json"
  gate --phase 2 --report "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  gate --phase 2 --report "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ]
}

# --- Gate: static violations ---

GREEN_TEST_LINES="  await page.goto('/checkout');
  await expect(page.getByRole('heading')).toBeVisible();"

# static_case <reason> <body>: a passed report cannot rescue this body.
static_case() {
  prepare_green
  green_body "$FILE_PHASE_TWO" "$2"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" "$1"
}

@test "gate refuses a leftover test.fail( with the annotation reason" {
  static_case annotation "test('t', async ({page}) => {
  test.fail();
$GREEN_TEST_LINES
});"
}

@test "gate refuses a conditional test.fail(condition) with the annotation reason" {
  static_case annotation "test('t', async ({page, browserName}) => {
  test.fail(browserName === 'webkit');
$GREEN_TEST_LINES
});"
}

@test "gate refuses test.only( with the annotation reason" {
  static_case annotation "test.only('t', async ({page}) => {
$GREEN_TEST_LINES
});"
}

@test "gate refuses test.skip( with the annotation reason" {
  static_case annotation "test('t', async ({page}) => {
  test.skip();
$GREEN_TEST_LINES
});"
}

@test "gate refuses test.fixme( with the annotation reason" {
  static_case annotation "test.fixme('t', async ({page}) => {
$GREEN_TEST_LINES
});"
}

@test "gate refuses test.describe.skip( with the annotation reason" {
  static_case annotation "test.describe.skip('group', () => {
  test('t', async ({page}) => {
$GREEN_TEST_LINES
  });
});"
}

@test "gate refuses test.describe.fixme( with the annotation reason" {
  static_case annotation "test.describe.fixme('group', () => {
  test('t', async ({page}) => {
$GREEN_TEST_LINES
  });
});"
}

@test "gate refuses a body of expect(true).toBe(true) with no page call with the floor reason" {
  static_case floor "test('t', async () => {
  expect(true).toBe(true);
});"
}

@test "gate refuses a page call whose only expect has a literal first argument with the floor reason" {
  static_case floor "test('t', async ({page}) => {
  await page.goto('/checkout');
  expect(true).toBe(true);
});"
}

@test "gate refuses string, number and null literal expects as the only assertions" {
  static_case floor "test('t', async ({page}) => {
  await page.goto('/checkout');
  expect('done, really').toBe('done, really');
  expect(1).toBe(1);
  expect(null).toBeNull();
});"
}

@test "gate refuses a non-literal expect with no page interaction with the floor reason" {
  static_case floor "test('t', async () => {
  expect(1 + 1).toBe(2);
});"
}

@test "gate refuses a spec whose Then-clause assert lives in a shared helper, naming the inline fix and no SPEC reopen" {
  static_case floor "import { expectConfirmation } from '../../utils';

test('the confirmation page shows the order number', async ({page}) => {
  await page.goto('/checkout');
  await expectConfirmation(page);
});"
  assert_stderr_names "uat-gate: next step for floor:" "test body" "never calls for reopening the SPEC"
}

@test "gate prints no floor next step when no file fails the floor" {
  static_case annotation "test('t', async ({page}) => {
  test.fail();
$GREEN_TEST_LINES
});"
  grep -qF -- "next step for floor" "$STDERR_FILE" && return 1
  true
}

@test "gate accepts a literal expect beside a real non-literal one" {
  prepare_green
  green_body "$FILE_PHASE_TWO" "test('t', async ({page}) => {
  expect(true).toBe(true);
  await page.goto('/checkout');
  await expect(page).toHaveURL(/checkout/);
});"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 0 ]
}

@test "gate refuses a missing spec file with the missing reason" {
  prepare_green
  rm -f "$FILE_PHASE_TWO"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" missing
}

@test "gate refuses a spec whose line 1 is not a contract marker with the missing reason" {
  prepare_green
  sed -i.bak '1s#.*#// not a marker#' "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" missing
}

@test "gate refuses the freshly rendered red spec: it still carries test.fail( and a literal expect" {
  write_spec
  render_specs
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" annotation floor
}

# --- Gate: the other two checks ---

@test "gate refuses an altered contract comment with the divergence reason" {
  prepare_green
  sed -i.bak 's#^// Then: .*#// Then: the confirmation page shows nothing#' "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" divergence
}

@test "gate refuses a working-document id anywhere under the Playwright tree with the working-doc-id reason" {
  prepare_green
  printf '// see UAT-123 for context\n' >"$WORK/apps/web/.playwright/helper.ts"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "apps/web/.playwright/helper.ts" working-doc-id
}

# --- Gate: selection ---

@test "gate --phase checks only that phase's e2e rows: a broken later phase does not fail it" {
  prepare_green
  [ -f "$FILE_PHASE_THREE" ]
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 0 ]
  [ ! -s "$STDERR_FILE" ]
}

@test "gate --all checks every e2e row and fails on the broken later phase only" {
  prepare_green
  gate --all --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_THREE_RELATIVE" annotation
  if grep -qF -- "$FILE_PHASE_TWO_RELATIVE" "$STDERR_FILE"; then
    return 1
  fi
}

@test "gate --all passes when every e2e row is green and reported passed" {
  prepare_green
  green_body "$FILE_PHASE_THREE" "test('every past order is listed newest first', async ({page}) => {
  await page.goto('/orders');
  await expect(page.getByRole('list')).toBeVisible();
});"
  gate --all --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 0 ]
}

@test "gate on a phase that owns no e2e or route rows prints no owned UAT tests and exits 0" {
  prepare_green
  gate --phase 1 --report "$REPORTS/failed.json"
  [ "$status" -eq 0 ]
  [ "$output" = "no owned UAT tests" ]
}

@test "gate refuses missing or conflicting selection arguments as invalid input" {
  prepare_green
  gate
  [ "$status" -eq 2 ]
  gate --phase 2 --all
  [ "$status" -eq 2 ]
  gate --phase two
  [ "$status" -eq 2 ]
}

@test "gate refuses an invalid routing table as invalid input" {
  prepare_green
  sed -i.bak '/UAT-003/d' "$ROUTING"
  rm -f "$ROUTING.bak"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 2 ]
}

# --- Gate: environment ---

# stub_pnpm <body>: a pnpm on PATH that runs the given shell body.
stub_pnpm() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\n%s\n' "$1" >"$BATS_TEST_TMPDIR/bin/pnpm"
  chmod +x "$BATS_TEST_TMPDIR/bin/pnpm"
}

gate_with_stub() {
  run bash -c "cd '$WORK' && PATH='$BATS_TEST_TMPDIR/bin':\"\$PATH\" bash '$GATE' '$SPEC' --routing '$ROUTING' --phase 2 2>'$STDERR_FILE'"
}

@test "gate exits 4 naming the prerequisite when Playwright cannot start" {
  prepare_green
  stub_pnpm "echo \"browserType.launch: Executable doesn't exist\" >&2
exit 1"
  gate_with_stub
  [ "$status" -eq 4 ]
  assert_stderr_names Chromium
}

@test "gate exits 4 when the report carries top-level errors such as a held port" {
  prepare_green
  stub_pnpm "printf '{\"errors\":[{\"message\":\"http://localhost:3000 is already used\"}],\"suites\":[]}' >\"\$PLAYWRIGHT_JSON_OUTPUT_NAME\"
exit 1"
  gate_with_stub
  [ "$status" -eq 4 ]
  assert_stderr_names Prerequisites
}

@test "gate exits 4 naming the other tree whose process holds this tree's dev port" {
  command -v node >/dev/null 2>&1 || skip "node is needed for the listener fixture"
  prepare_green
  git init -q -b main "$WORK"
  mkdir -p "$WORK/apps/web"
  : >"$WORK/apps/web/react-router.config.ts"
  other_tree="$BATS_TEST_TMPDIR/other-tree"
  git init -q -b main "$other_tree"
  other_tree="$(cd "$other_tree" && pwd -P)"
  held_port=$((28000 + (RANDOM % 2000)))
  listener_log="$BATS_TEST_TMPDIR/listener.log"
  (cd "$other_tree" && nohup node "$REPO_ROOT_REAL/.gaia/tests/fixtures/ports/listen.mjs" "$held_port" 127.0.0.1 >"$listener_log" 2>&1 </dev/null 3>&- &)
  attempt=0
  until grep -q '^listening ' "$listener_log" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || return 1
    sleep 0.1
  done
  listener_pid="$(sed -n 's/^listening \([0-9][0-9]*\)$/\1/p' "$listener_log")"
  stub_pnpm "printf '{\"errors\":[{\"message\":\"http://localhost:$held_port is already used\"}],\"suites\":[]}' >\"\$PLAYWRIGHT_JSON_OUTPUT_NAME\"
exit 1"
  GAIA_PORTS_DEV_BASE_PORT="$held_port" gate_with_stub
  kill "$listener_pid" 2>/dev/null || true
  [ "$status" -eq 4 ]
  assert_stderr_names "Port $held_port is held by process $listener_pid running from $other_tree, which is not this tree: ask the user before stopping it."
}

# gate_with_listener_owner <answer>: run the gate from a copy of the spec scripts
# whose sibling ports.sh and server-process-lib.sh are stubs, so the holder
# answer is chosen by the test.
gate_with_listener_owner() {
  local fake_root="$BATS_TEST_TMPDIR/fake-root"
  local fake_scripts="$fake_root/.gaia/scripts"
  mkdir -p "$fake_scripts"
  ln -s "$REPO_ROOT_REAL/.claude" "$fake_root/.claude"
  cp -R "$SCRIPTS" "$fake_scripts/spec"
  printf '#!/usr/bin/env bash\necho 4321\n' >"$fake_scripts/ports.sh"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$1" >"$fake_scripts/server-process-lib.sh"
  run bash -c "cd '$WORK' && PATH='$BATS_TEST_TMPDIR/bin':\"\$PATH\" bash '$fake_scripts/spec/uat-gate.sh' '$SPEC' --routing '$ROUTING' --phase 2 2>'$STDERR_FILE'"
}

@test "gate does not claim a directory when the holder's directory could not be read" {
  prepare_green
  stub_pnpm "printf '{\"errors\":[{\"message\":\"already used\"}],\"suites\":[]}' >\"\$PLAYWRIGHT_JSON_OUTPUT_NAME\"
exit 1"
  gate_with_listener_owner "foreign 777 unknown"
  [ "$status" -eq 4 ]
  assert_stderr_names "Port 4321 is held by process 777, whose directory GAIA could not read: ask the user before stopping it."
  ! grep -qF "running from" "$STDERR_FILE"
}

@test "gate does not claim a process when no holder could be identified" {
  prepare_green
  stub_pnpm "printf '{\"errors\":[{\"message\":\"already used\"}],\"suites\":[]}' >\"\$PLAYWRIGHT_JSON_OUTPUT_NAME\"
exit 1"
  gate_with_listener_owner "foreign 0 unknown"
  [ "$status" -eq 4 ]
  assert_stderr_names "Port 4321 is held by a process GAIA could not identify: ask the user before stopping it."
  ! grep -qF "process 0" "$STDERR_FILE"
}

@test "gate runs Playwright over only the owned file with the JSON reporter and reads its report" {
  prepare_green
  stub_pnpm "printf '%s\n' \"\$@\" >'$BATS_TEST_TMPDIR/pnpm-args'
cp '$REPORTS/passed.json' \"\$PLAYWRIGHT_JSON_OUTPUT_NAME\"
exit 0"
  gate_with_stub
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' <"$BATS_TEST_TMPDIR/pnpm-args")" = "-C apps/web exec playwright test .playwright/e2e/checkout/guest-checkout-confirms-order.spec.ts --reporter=json " ]
}

@test "gate does not start Playwright when a static check already failed" {
  write_spec
  render_specs
  stub_pnpm "echo started >'$BATS_TEST_TMPDIR/pnpm-ran'"
  gate_with_stub
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/pnpm-ran" ]
}

# --- Gate: the e2e floor accepts Playwright's request fixture ---

REQUEST_GET_LINES="  const response = await request.get('/api/orders');
  expect(response.status()).toBe(200);"

@test "gate accepts an e2e spec that uses the request fixture and no page call" {
  prepare_green
  green_body "$FILE_PHASE_TWO" "test('t', async ({request}) => {
$REQUEST_GET_LINES
});"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 0 ]
}

@test "gate refuses an e2e spec with a real assertion and no page or request call, naming both accepted forms" {
  static_case floor "test('t', async () => {
  const response = await fetchOrders();
  expect(response.status).toBe(200);
});"
  assert_stderr_names "page.<method>(" "request.get("
}

@test "gate refuses an e2e spec that only mentions a request call in a comment or string" {
  static_case floor "test('t', async () => {
  // request.get('/api/orders')
  const text = 'request.post(';
  expect(text.length).toBe(13);
});"
}

@test "gate accepts a spec that gets its API context from request.newContext" {
  prepare_green
  green_body "$FILE_PHASE_TWO" "test('t', async ({playwright}) => {
  const api = await playwright.request.newContext();
  const response = await api.get('/api/orders');
  expect(response.status()).toBe(200);
});"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 0 ]
}

@test "gate refuses a request.newContext spec that never calls a verb on it" {
  static_case floor "test('t', async ({playwright}) => {
  const api = await playwright.request.newContext();
  expect(api).toBeDefined();
});"
}

# --- Gate: the route arm ---

ROUTE_GREEN_LINES="  const response = await loader({request: new Request('http://localhost/orders')});
  expect(response.status).toBe(200);"

# prepare_route [<phase>]: UAT-003 routes to a Vitest route test in the given
# phase (default 3); the rendered red test is replaced by a green body.
prepare_route() {
  write_spec
  sed -i.bak "s#^| UAT-003 | browser | 3 | orders | order-history-lists-orders.spec.ts |#| UAT-003 | route | ${1:-3} | orders | order-history-lists-orders.test.ts |#" "$ROUTING"
  rm -f "$ROUTING.bak"
  grep -qF -- '| UAT-003 | route |' "$ROUTING" || return 1
  render_specs
  [ -f "$ROUTE_FILE" ] || return 1
  green_body "$ROUTE_FILE" "test('every past order is listed', async () => {
$ROUTE_GREEN_LINES
});"
}

# route_case <reason> <body>: a passing Vitest report cannot rescue this body.
route_case() {
  prepare_route
  green_body "$ROUTE_FILE" "$2"
  gate --phase 3 --vitest-report "$VITEST_REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$ROUTE_FILE_RELATIVE" "$1"
}

# stub_vitest <fixture>: a pnpm on PATH that logs its arguments and, for a
# vitest run, writes the fixture to the requested output file.
stub_vitest() {
  stub_pnpm "echo \"\$*\" >>'$BATS_TEST_TMPDIR/pnpm-log'
for argument in \"\$@\"; do
  case \"\$argument\" in --outputFile=*) cp '$1' \"\${argument#--outputFile=}\" ;; esac
done
exit 1"
}

@test "the committed Vitest report fixtures are the full set the route cases drive" {
  local expected="collection-failed failed no-entry no-tests passed skipped todo" found report
  found=$(cd "$VITEST_REPORTS" && ls ./*.json | sed 's#^\./##; s#\.json$##' | LC_ALL=C sort | tr '\n' ' ')
  [ "${found% }" = "$expected" ]
  for report in "$VITEST_REPORTS"/*.json; do
    jq -e 'has("testResults") and has("numTotalTests")' "$report" >/dev/null
  done
}

@test "gate refuses the freshly rendered route test: it still carries test.fails" {
  prepare_route
  rm -f "$ROUTE_FILE"
  render_specs
  gate --phase 3 --vitest-report "$VITEST_REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$ROUTE_FILE_RELATIVE" annotation
}

@test "gate passes a green route test from a supplied Vitest report without starting Vitest or Playwright" {
  prepare_route
  stub_vitest "$VITEST_REPORTS/passed.json"
  run bash -c "cd '$WORK' && PATH='$BATS_TEST_TMPDIR/bin':\"\$PATH\" bash '$GATE' '$SPEC' --routing '$ROUTING' --phase 3 --vitest-report '$VITEST_REPORTS/passed.json' 2>'$STDERR_FILE'"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pnpm-log" ]
}

@test "gate runs Vitest, and never Playwright, for a route-only phase" {
  prepare_route
  stub_vitest "$VITEST_REPORTS/passed.json"
  run bash -c "cd '$WORK' && PATH='$BATS_TEST_TMPDIR/bin':\"\$PATH\" bash '$GATE' '$SPEC' --routing '$ROUTING' --phase 3 2>'$STDERR_FILE'"
  [ "$status" -eq 0 ]
  [ "$output" != "no owned e2e specs" ]
  grep -qF -- "-C apps/web exec vitest run --project node --reporter=json --outputFile=" "$BATS_TEST_TMPDIR/pnpm-log"
  grep -qF -- "app/route-tests/orders/tests/order-history-lists-orders.test.ts" "$BATS_TEST_TMPDIR/pnpm-log"
  if grep -q playwright "$BATS_TEST_TMPDIR/pnpm-log"; then return 1; fi
}

@test "gate refuses an altered route contract comment with the divergence reason" {
  prepare_route
  sed -i.bak 's#^// Then: .*#// Then: something else entirely#' "$ROUTE_FILE"
  rm -f "$ROUTE_FILE.bak"
  gate --phase 3 --vitest-report "$VITEST_REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$ROUTE_FILE_RELATIVE" divergence
}

@test "gate refuses a route test whose only expect is on a bare literal with the floor reason" {
  route_case floor "test('t', async () => {
  await loader({request: new Request('http://localhost/orders')});
  expect(true).toBe(true);
});"
}

@test "gate refuses a route test with a real assertion and no loader or action call, naming loader or action and never page" {
  route_case floor "test('t', async () => {
  const response = await fetchOrders();
  expect(response.status).toBe(200);
});"
  assert_stderr_names "loader( or action("
  if grep -qF 'page.<method>(' "$STDERR_FILE"; then return 1; fi
}

@test "gate refuses a route test whose only route call is new Request with the floor reason" {
  route_case floor "test('t', async () => {
  const request = new Request('http://localhost/orders');
  expect(request.method).toBe('GET');
});"
}

@test "gate accepts an action call through member access, and a loader word inside a longer identifier is no call" {
  prepare_route
  green_body "$ROUTE_FILE" "test('t', async () => {
  const response = await route.action({request: new Request('http://localhost/orders', {method: 'POST'})});
  expect(response.status).toBe(200);
});"
  gate --phase 3 --vitest-report "$VITEST_REPORTS/passed.json"
  [ "$status" -eq 0 ]
  route_case floor "test('t', async () => {
  await preloader(1);
  expect(1 + 1).toBe(2);
});"
}

@test "gate accepts loader and action calls through a named-import alias" {
  prepare_route
  green_body "$ROUTE_FILE" "import {loader as requestList} from '../../orders/route';
test('t', async () => {
  const response = await requestList({request: new Request('http://localhost/orders')});
  expect(response.status).toBe(200);
});"
  gate --phase 3 --vitest-report "$VITEST_REPORTS/passed.json"
  [ "$status" -eq 0 ]
  green_body "$ROUTE_FILE" "import {
  meta,
  action as signOut,
} from '../../sign-out/route';
test('t', async () => {
  const response = await signOut({request: new Request('http://localhost/sign-out', {method: 'POST'})});
  expect(response.status).toBe(302);
});"
  gate --phase 3 --vitest-report "$VITEST_REPORTS/passed.json"
  [ "$status" -eq 0 ]
}

@test "gate refuses a loader alias that is never called with the floor reason" {
  route_case floor "import {loader as requestList} from '../../orders/route';
test('t', async () => {
  const request = new Request('http://localhost/orders');
  expect(request.method).toBe('GET');
});"
}

@test "gate refuses a call through a type cast of loader, which is no import alias, with the floor reason" {
  route_case floor "import {loader} from '../../orders/route';
test('t', async () => {
  const handler = pick(1, loader as Handler);
  const response = await Handler({request: new Request('http://localhost/orders')});
  expect(response.status).toBe(200);
});"
}

@test "gate refuses a call through an alias of another export with the floor reason" {
  route_case floor "import {meta as loader2} from '../../orders/route';
test('t', async () => {
  const result = await loader2({request: new Request('http://localhost/orders')});
  expect(result.title).toBe('Orders');
});"
}

@test "gate refuses test.todo in a route test with the annotation reason" {
  route_case annotation "test.todo('later');
test('t', async () => {
$ROUTE_GREEN_LINES
});"
}

@test "gate refuses it.fails( in a route test with the annotation reason" {
  route_case annotation "it.fails('t', async () => {
$ROUTE_GREEN_LINES
});"
}

@test "gate refuses test.fails.each( in a route test with the annotation reason" {
  route_case annotation "test.fails.each([1])('t', async () => {
$ROUTE_GREEN_LINES
});"
}

@test "gate refuses a skipped describe in a route test with the annotation reason" {
  route_case annotation "describe.skip('group', () => {
  test('t', async () => {
$ROUTE_GREEN_LINES
  });
});"
}

@test "gate refuses test.concurrent.skip in a route test with the annotation reason" {
  route_case annotation "test.concurrent.skip('t', async () => {
$ROUTE_GREEN_LINES
});"
}

@test "gate refuses the fails: true option in a route test with the annotation reason" {
  route_case annotation "test('t', {fails: true}, async () => {
$ROUTE_GREEN_LINES
});"
}

@test "gate refuses test.skipIf( and test.runIf( in a route test with the annotation reason" {
  route_case annotation "test.skipIf(process.env.CI)('t', async () => {
$ROUTE_GREEN_LINES
});"
  route_case annotation "test.runIf(process.env.CI)('t', async () => {
$ROUTE_GREEN_LINES
});"
}

@test "gate refuses test.only in a route test with the annotation reason" {
  route_case annotation "test.only('t', async () => {
$ROUTE_GREEN_LINES
});"
}

@test "gate ignores an annotation word inside a route test's comment or string" {
  prepare_route
  green_body "$ROUTE_FILE" "// test.skip( and test.fails( and fails: true are not allowed here
test('test.todo it.fails( fails: true', async () => {
  /* describe.skip( */
$ROUTE_GREEN_LINES
});"
  gate --phase 3 --vitest-report "$VITEST_REPORTS/passed.json"
  [ "$status" -eq 0 ]
}

@test "gate exits 4 naming Vitest and its prerequisite when Vitest writes no report" {
  prepare_route
  stub_pnpm "echo 'no vitest config' >&2
exit 1"
  run bash -c "cd '$WORK' && PATH='$BATS_TEST_TMPDIR/bin':\"\$PATH\" bash '$GATE' '$SPEC' --routing '$ROUTING' --phase 3 2>'$STDERR_FILE'"
  [ "$status" -eq 4 ]
  assert_stderr_names Vitest Prerequisites "no vitest config"
}

@test "gate refuses a Vitest report that is not JSON, and one that does not exist, as invalid input" {
  prepare_route
  printf 'not json\n' >"$BATS_TEST_TMPDIR/bad.json"
  gate --phase 3 --vitest-report "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  gate --phase 3 --vitest-report "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ]
}

# report_case <fixture> <reason>
report_case() {
  prepare_route
  gate --phase 3 --vitest-report "$VITEST_REPORTS/$1.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$ROUTE_FILE_RELATIVE" "$2"
}

@test "gate refuses a route report with a failed test with the failed reason" {
  report_case failed failed
}

@test "gate refuses a route report with a skipped test with the skipped reason" {
  report_case skipped skipped
}

@test "gate refuses a route report with no tests for the file with the no-tests reason" {
  report_case no-tests no-tests
}

@test "gate refuses a route report whose file failed to collect with the collection-failed reason" {
  report_case collection-failed collection-failed
}

@test "gate refuses a route report with no entry for the file with the no-report-entry reason" {
  report_case no-entry no-report-entry
}

@test "gate refuses a route report with a todo test with the todo reason" {
  report_case todo todo
}

@test "gate refuses a route report holding an unknown assertion status" {
  prepare_route
  jq '.testResults[0].assertionResults[0].status = "mystery"' "$VITEST_REPORTS/passed.json" >"$BATS_TEST_TMPDIR/unknown.json"
  gate --phase 3 --vitest-report "$BATS_TEST_TMPDIR/unknown.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$ROUTE_FILE_RELATIVE" failed
}

@test "gate --all checks one e2e and one route row, each failing alone naming its own file" {
  prepare_route
  green_body "$FILE_PHASE_TWO"
  gate --all --report "$REPORTS/passed.json" --vitest-report "$VITEST_REPORTS/passed.json"
  [ "$status" -eq 0 ]
  gate --all --report "$REPORTS/passed.json" --vitest-report "$VITEST_REPORTS/failed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$ROUTE_FILE_RELATIVE"
  if grep -qF "$FILE_PHASE_TWO_RELATIVE" "$STDERR_FILE"; then return 1; fi
  gate --all --report "$REPORTS/failed.json" --vitest-report "$VITEST_REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE"
  if grep -qF "$ROUTE_FILE_RELATIVE" "$STDERR_FILE"; then return 1; fi
}

@test "gate stops a mixed phase at a Vitest failure and never starts Playwright" {
  prepare_route 2
  green_body "$FILE_PHASE_TWO"
  stub_vitest "$VITEST_REPORTS/failed.json"
  run bash -c "cd '$WORK' && PATH='$BATS_TEST_TMPDIR/bin':\"\$PATH\" bash '$GATE' '$SPEC' --routing '$ROUTING' --phase 2 2>'$STDERR_FILE'"
  [ "$status" -eq 1 ]
  assert_stderr_names "$ROUTE_FILE_RELATIVE" failed
  grep -qF -- "exec vitest run" "$BATS_TEST_TMPDIR/pnpm-log"
  if grep -q playwright "$BATS_TEST_TMPDIR/pnpm-log"; then return 1; fi
}

@test "gate runs the Playwright arm after a green route arm in a mixed phase" {
  prepare_route 2
  green_body "$FILE_PHASE_TWO"
  stub_vitest "$VITEST_REPORTS/passed.json"
  run bash -c "cd '$WORK' && PATH='$BATS_TEST_TMPDIR/bin':\"\$PATH\" bash '$GATE' '$SPEC' --routing '$ROUTING' --phase 2 --report '$REPORTS/passed.json' 2>'$STDERR_FILE'"
  [ "$status" -eq 0 ]
  grep -qF -- "exec vitest run" "$BATS_TEST_TMPDIR/pnpm-log"
}

# --- Divergence check ---

divergence() {
  run bash -c "cd '$WORK' && bash '$DIVERGENCE' '$SPEC' --routing '$ROUTING' $* 2>'$STDERR_FILE'"
}

@test "divergence passes freshly rendered specs" {
  write_spec
  render_specs
  divergence --all
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "divergence names the file, the UAT and then when the Then line was altered" {
  write_spec
  render_specs
  sed -i.bak 's#^// Then: .*#// Then: something else entirely#' "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  divergence --all
  [ "$status" -eq 1 ]
  [ "$output" = "$FILE_PHASE_TWO_RELATIVE UAT-002 then" ]
}

@test "divergence names the route test path, the UAT and then when a route test's Then line was altered" {
  write_spec
  sed -i.bak 's#^| UAT-003 | browser | 3 | orders | order-history-lists-orders.spec.ts |#| UAT-003 | route | 3 | orders | order-history-lists-orders.test.ts |#' "$ROUTING"
  rm -f "$ROUTING.bak"
  grep -qF -- '| UAT-003 | route |' "$ROUTING" || return 1
  render_specs
  route_file="$WORK/apps/web/app/route-tests/orders/tests/order-history-lists-orders.test.ts"
  [ -f "$route_file" ] || return 1
  divergence --all
  [ "$status" -eq 0 ] || return 1
  sed -i.bak 's#^// Then: .*#// Then: something else entirely#' "$route_file"
  rm -f "$route_file.bak"
  divergence --all
  [ "$status" -eq 1 ]
  [ "$output" = "apps/web/app/route-tests/orders/tests/order-history-lists-orders.test.ts UAT-003 then" ]
}

@test "divergence ignores a body edit of selectors, labels and copy" {
  write_spec
  render_specs
  green_body "$FILE_PHASE_TWO" "test('a reworded title', async ({page}) => {
  await page.getByTestId('checkout-button').click();
  await expect(page.getByText('Thanks for your order')).toBeVisible();
});"
  divergence --all
  [ "$status" -eq 0 ]
}

@test "divergence still matches a contract line reformatted only in whitespace" {
  write_spec
  render_specs
  sed -i.bak 's#^// When: .*#// When:   they   check out as a   guest   #' "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  divergence --all
  [ "$status" -eq 0 ]
}

@test "divergence fails on a missing When line, naming when" {
  write_spec
  render_specs
  sed -i.bak '/^\/\/ When: /d' "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  divergence --all
  [ "$status" -eq 1 ]
  [ "$output" = "$FILE_PHASE_TWO_RELATIVE UAT-002 when" ]
}

@test "divergence fails on a missing spec file, naming file" {
  write_spec
  render_specs
  rm -f "$FILE_PHASE_THREE"
  divergence --all
  [ "$status" -eq 1 ]
  [ "$output" = "$FILE_PHASE_THREE_RELATIVE UAT-003 file" ]
}

@test "divergence --phase selects only that phase's rows" {
  write_spec
  render_specs
  sed -i.bak 's#^// Given: .*#// Given: nobody#' "$FILE_PHASE_THREE"
  rm -f "$FILE_PHASE_THREE.bak"
  divergence --phase 2
  [ "$status" -eq 0 ]
  divergence --phase 3
  [ "$status" -eq 1 ]
  [ "$output" = "$FILE_PHASE_THREE_RELATIVE UAT-003 given" ]
}

# quoted_then_case <yaml-then-scalar> <rendered-then> <word> <replacement>:
# render, expect a match, then change one inner word of the Then line and
# expect a mismatch.
quoted_then_case() {
  write_spec "$1"
  render_specs
  divergence --all
  [ "$status" -eq 0 ]
  grep -qxF -- "// Then: $2" "$FILE_PHASE_TWO"
  sed -i.bak "/^\/\/ Then: /s/$3/$4/" "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  divergence --all
  [ "$status" -eq 1 ]
  [ "$output" = "$FILE_PHASE_TWO_RELATIVE UAT-002 then" ]
}

@test "divergence reads back a freshly rendered then-clause wrapped in double quotes, and flags one changed word" {
  quoted_then_case "'\"Saved\" toast reads \"Done\"'" '"Saved" toast reads "Done"' Done Finished
}

@test "divergence reads back a freshly rendered then-clause wrapped in single quotes, and flags one changed word" {
  quoted_then_case "\"'Saved' toast reads 'Done'\"" "'Saved' toast reads 'Done'" Done Finished
}

@test "divergence refuses an invalid routing table as invalid input" {
  write_spec
  render_specs
  sed -i.bak '/UAT-003/d' "$ROUTING"
  rm -f "$ROUTING.bak"
  divergence --all
  [ "$status" -eq 2 ]
}

# --- Working-document id scan ---

SCAN_TREE="scan-tree"

scan_tree() {
  mkdir -p "$BATS_TEST_TMPDIR/$SCAN_TREE/e2e"
  cat >"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/clean.spec.ts" <<'TREE_EOF'
import {test} from '@playwright/test';
test('a clean title', async () => {});
TREE_EOF
}

scan() {
  run bash -c "cd '$BATS_TEST_TMPDIR' && bash '$SCAN' '$SCAN_TREE' 2>'$STDERR_FILE'"
}

@test "scan exits zero on a clean tree" {
  scan_tree
  scan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scan names path:line for an id in a test title" {
  scan_tree
  printf "test('UAT-007 shows the total', async () => {});\n" >>"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/clean.spec.ts"
  scan
  [ "$status" -eq 1 ]
  [ "$output" = "$SCAN_TREE/e2e/clean.spec.ts:3: UAT-007" ]
}

@test "scan names path:line for an id in a line comment, case-insensitively" {
  scan_tree
  printf '// derived from spec-12\n// plan-3 owns this\n' >>"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/clean.spec.ts"
  scan
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "$SCAN_TREE/e2e/clean.spec.ts:3: spec-12" ]
  [ "$(printf '%s\n' "$output" | sed -n '2p')" = "$SCAN_TREE/e2e/clean.spec.ts:4: plan-3" ]
}

@test "scan names path:line for an id in a block comment" {
  scan_tree
  printf '/*\n * covers SPEC-110\n */\n' >>"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/clean.spec.ts"
  scan
  [ "$status" -eq 1 ]
  [ "$output" = "$SCAN_TREE/e2e/clean.spec.ts:4: SPEC-110" ]
}

@test "scan names the path for an id in a path segment" {
  scan_tree
  mkdir -p "$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/uat-004-checkout"
  printf 'export {};\n' >"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/uat-004-checkout/total.spec.ts"
  scan
  [ "$status" -eq 1 ]
  [ "$output" = "$SCAN_TREE/e2e/uat-004-checkout/total.spec.ts:0: uat-004" ]
}

@test "scan ignores a hit under output/" {
  scan_tree
  mkdir -p "$BATS_TEST_TMPDIR/$SCAN_TREE/output"
  printf 'UAT-001 artifact\n' >"$BATS_TEST_TMPDIR/$SCAN_TREE/output/trace.txt"
  scan
  [ "$status" -eq 0 ]
}

@test "scan treats an id-looking word without digits as clean" {
  scan_tree
  printf '// the spec- and uat- prefixes are fine without a number\n' >>"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/clean.spec.ts"
  scan
  [ "$status" -eq 0 ]
}

@test "scan refuses a missing directory as invalid input" {
  run bash -c "cd '$BATS_TEST_TMPDIR' && bash '$SCAN' no-such-directory 2>'$STDERR_FILE'"
  [ "$status" -eq 2 ]
}

@test "default scan with no app/route-tests folder exits zero; an id planted in a route test exits 1 naming the file" {
  mkdir -p "$WORK/apps/web/.playwright/e2e"
  run bash -c "cd '$WORK' && bash '$SCAN' 2>'$STDERR_FILE'"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
  mkdir -p "$WORK/apps/web/app/route-tests/checkout/tests"
  printf '// covers UAT-004\n' >"$WORK/apps/web/app/route-tests/checkout/tests/total.test.ts"
  run bash -c "cd '$WORK' && bash '$SCAN' 2>'$STDERR_FILE'"
  [ "$status" -eq 1 ]
  [ "$output" = "apps/web/app/route-tests/checkout/tests/total.test.ts:1: UAT-004" ]
}

# bats test_tags=whole-tree
@test "scan over this repository's own Playwright tree exits zero today" {
  run bash -c "cd '$REPO_ROOT_REAL' && bash '$SCAN'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Gate: legacy e2e rows read as browser; real-server rows are selected ---

# legacy_routing: the routing table with every browser row written as the
# legacy e2e surface.
legacy_routing() {
  sed -i.bak 's/| browser |/| e2e |/' "$ROUTING"
  rm -f "$ROUTING.bak"
  grep -qF -- '| e2e |' "$ROUTING"
}

@test "a legacy e2e row gates the same as a browser row: pass on a passed report, same reason on a failed one, counted as owned" {
  prepare_green
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 0 ] || return 1
  browser_pass_output="$output"
  gate --phase 2 --report "$REPORTS/failed.json"
  [ "$status" -eq 1 ] || return 1
  browser_failure=$(cat "$STDERR_FILE")

  legacy_routing
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "$browser_pass_output" ] || return 1
  [ "$output" != "no owned UAT tests" ] || return 1
  gate --phase 2 --report "$REPORTS/failed.json"
  [ "$status" -eq 1 ] || return 1
  [ "$(cat "$STDERR_FILE")" = "$browser_failure" ]
}

# prepare_mixed: UAT-002 browser (phase 2) and UAT-003 real-server (phase 3),
# both rendered and given a passing-looking body.
prepare_mixed() {
  write_spec
  sed -i.bak 's/| UAT-003 | browser |/| UAT-003 | real-server |/' "$ROUTING"
  rm -f "$ROUTING.bak"
  render_specs
  green_body "$FILE_PHASE_TWO"
  green_body "$FILE_PHASE_THREE" "test('every past order is listed newest first', async ({request}) => {
  const response = await request.get('/orders');
  expect(response.status()).toBe(200);
});"
}

@test "divergence reports a mutated Then line in a browser file and in a real-server file, and passes when both match" {
  prepare_mixed
  run bash -c "cd '$WORK' && bash '$DIVERGENCE' '$SPEC' --routing '$ROUTING' --all"
  [ "$status" -eq 0 ] || return 1
  cp "$FILE_PHASE_TWO" "$BATS_TEST_TMPDIR/original.spec.ts"
  sed -i.bak 's#^// Then: .*#// Then: mutated#' "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  run bash -c "cd '$WORK' && bash '$DIVERGENCE' '$SPEC' --routing '$ROUTING' --all"
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "$FILE_PHASE_TWO_RELATIVE UAT-002 then" ] || return 1
  cp "$BATS_TEST_TMPDIR/original.spec.ts" "$FILE_PHASE_TWO"
  sed -i.bak 's#^// Then: .*#// Then: mutated#' "$FILE_PHASE_THREE"
  rm -f "$FILE_PHASE_THREE.bak"
  run bash -c "cd '$WORK' && bash '$DIVERGENCE' '$SPEC' --routing '$ROUTING' --all"
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "$FILE_PHASE_THREE_RELATIVE UAT-003 then" ]
}

@test "divergence fails closed on an unknown surface: exit 2 and no file named" {
  write_spec
  sed -i.bak 's/| UAT-003 | browser |/| UAT-003 | desktop |/' "$ROUTING"
  rm -f "$ROUTING.bak"
  run bash -c "cd '$WORK' && bash '$DIVERGENCE' '$SPEC' --routing '$ROUTING' --all 2>/dev/null"
  [ "$status" -eq 2 ] || return 1
  [ -z "$output" ]
}
