#!/usr/bin/env bats
#
# The owning-phase UAT gate's real-server arm (uat-gate.sh and
# uat-gate-floor.sh): a rendered real-server test must call a request context
# and must open no page. The no-page verdict comes from the shared detector
# (page-use.mjs), which reads the file's AST through the `typescript` package,
# so this is a node-dependent suite. The gate's Playwright step runs through
# --report with a committed JSON report, so no browser runs.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/uat-gate-no-page.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

bats_require_minimum_version 1.5.0

NEXT_STEP_LITERAL='uat-gate: next step for opens-page: a real-server test must not open a page; drive it through the request fixture and read rendered HTML with the helper in .playwright/html.ts. When the Then-clause truly needs a browser, the routing row is wrong: stop and report it instead of editing the test.'

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$REPO_ROOT_REAL"
  SCRIPTS="$REPO_ROOT_REAL/.gaia/scripts/spec"
  GATE="$SCRIPTS/uat-gate.sh"
  WRITER="$SCRIPTS/uat-write.sh"
  REPORTS="$BATS_TEST_DIRNAME/../lib/fixtures/uat-gate"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/plan"
  write_builtin_descriptor "$WORK"
  SPEC="$WORK/SPEC.md"
  ROUTING="$WORK/plan/README.md"
  STDERR_FILE="$BATS_TEST_TMPDIR/stderr"
  TARGET_RELATIVE='apps/web/.playwright/e2e/orders/order-history-lists-orders.spec.ts'
  TARGET="$WORK/$TARGET_RELATIVE"
}

# prepare <surface> <body>: a SPEC whose only UAT is routed to <surface>
# (phase 1), rendered through the real renderer, its red body replaced by <body>.
prepare() {
  local surface="$1" body="$2" header="$BATS_TEST_TMPDIR/header"
  cat >"$SPEC" <<'SPEC_EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a signed in member
    when: they open the order history
    then: every past order is listed newest first
---
SPEC_EOF
  cat >"$ROUTING" <<ROUTING_EOF
# Plan

<!-- gaia:uat-routing:start -->
| uat_id | surface | phase | feature_folder | file_name |
|---|---|---|---|---|
| UAT-001 | $surface | 1 | orders | order-history-lists-orders.spec.ts |
<!-- gaia:uat-routing:end -->
ROUTING_EOF
  (cd "$WORK" && bash "$WRITER" "$SPEC" --routing "$ROUTING" >/dev/null)
  sed -n '1,/^import /p' "$TARGET" >"$header"
  {
    cat "$header"
    printf '\n%s\n' "$body"
  } >"$TARGET"
  rm -f "$header"
}

# gate <argument>...: run the real gate from the fixture root.
gate() {
  run bash -c "cd '$WORK' && bash '${GATE_UNDER_TEST:-$GATE}' '$SPEC' --routing '$ROUTING' $* 2>'$STDERR_FILE'"
}

stderr_has() {
  local needle
  for needle in "$@"; do
    grep -qF -- "$needle" "$STDERR_FILE" || return 1
  done
}

stderr_lacks() {
  grep -qF -- "$1" "$STDERR_FILE" && return 1
  return 0
}

# refuses_opens_page <body>: a real-server test with <body> exits 1, names the
# file with opens-page, and prints the one next-step line.
refuses_opens_page() {
  prepare real-server "$1"
  gate --phase 1 --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 1 ] || return 1
  grep -qE "^uat-gate: $TARGET_RELATIVE: .*opens-page" "$STDERR_FILE" || return 1
  stderr_has "$NEXT_STEP_LITERAL" || return 1
  stderr_has 'a real-server test must not open a page'
}

# --- UAT-003 fixture table: every shape that opens a page is refused ---

@test "a real-server test calling page.goto( with page and request destructured is refused" {
  refuses_opens_page "test('every past order is listed newest first', async ({page, request}) => {
  const response = await request.get('/orders');
  await page.goto('/orders');
  expect(response.status()).toBe(200);
});"
}

@test "a real-server test that opens a page through an imported helper is refused" {
  refuses_opens_page "import {openHome} from './helpers';

test('every past order is listed newest first', async ({page, request}) => {
  const response = await request.get('/orders');
  await openHome(page);
  expect(response.status()).toBe(200);
});"
}

@test "a real-server test calling browser.newPage() is refused" {
  refuses_opens_page "test('every past order is listed newest first', async ({browser, request}) => {
  const response = await request.get('/orders');
  const opened = await browser.newPage();
  expect(response.status()).toBe(200);
  await opened.close();
});"
}

@test "a real-server test using an in-file page-backed project fixture is refused" {
  refuses_opens_page "const withSignedIn = test.extend({
  signedInPage: async ({page}, use) => {
    await use(page);
  },
});

withSignedIn('every past order is listed newest first', async ({signedInPage, request}) => {
  const response = await request.get('/orders');
  await signedInPage.goto('/orders');
  expect(response.status()).toBe(200);
});"
}

@test "a real-server test destructuring the template makeAxeBuilder fixture is refused" {
  refuses_opens_page "test('every past order is listed newest first', async ({makeAxeBuilder, request}) => {
  const response = await request.get('/orders');
  expect(response.status()).toBe(200);
  expect(makeAxeBuilder).toBeDefined();
});"
}

@test "a real-server test reaching the browser context's request is refused" {
  refuses_opens_page "test('every past order is listed newest first', async ({context}) => {
  const created = await context.request.post('/orders');
  const response = await request.get('/orders');
  expect(created.status()).toBe(201);
  expect(response.status()).toBe(200);
});"
}

# --- Negative cases ---

@test "a request-only real-server test whose title, strings and comments say page passes" {
  prepare real-server "// The page that lists orders is rendered by the server.
test('the order history page lists every past order', async ({request}) => {
  const response = await request.get('/orders?page=1');
  const html = await response.text();
  expect(html).toContain('page 1 of orders');
});"
  gate --phase 1 --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 0 ] || return 1
  stderr_lacks opens-page
}

@test "the same page-opening body on a browser row is not refused for opens-page" {
  prepare browser "test('every past order is listed newest first', async ({page, request}) => {
  const response = await request.get('/orders');
  await page.goto('/orders');
  expect(response.status()).toBe(200);
});"
  gate --phase 1 --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 0 ] || return 1
  stderr_lacks opens-page
}

# --- Real-server floor ---

@test "a real-server test whose only call is page.goto( fails the floor and opens-page" {
  prepare real-server "test('every past order is listed newest first', async ({page}) => {
  await page.goto('/orders');
  expect(await page.title()).toBe('Orders');
});"
  gate --phase 1 --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 1 ] || return 1
  grep -qE "^uat-gate: $TARGET_RELATIVE: floor,opens-page\$" "$STDERR_FILE" || return 1
  stderr_has 'uat-gate: next step for floor: the real-server test file itself must call a verb on the request fixture' "$NEXT_STEP_LITERAL"
}

@test "a real-server test with request.get( and a literal-only expect fails the floor but not opens-page" {
  prepare real-server "test('every past order is listed newest first', async ({request}) => {
  await request.get('/orders');
  expect(true).toBe(true);
});"
  gate --phase 1 --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 1 ] || return 1
  grep -qE "^uat-gate: $TARGET_RELATIVE: floor\$" "$STDERR_FILE" || return 1
  stderr_lacks opens-page
}

@test "a real-server test with request.get( and a non-literal expect clears the floor" {
  prepare real-server "test('every past order is listed newest first', async ({request}) => {
  const response = await request.get('/orders');
  expect(response.status()).toBe(200);
});"
  gate --phase 1 --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 0 ]
}

# signed_in_body <fixture-name>: a worker-scoped request-context fixture built
# with playwright.request.newContext, destructured by name in the test.
signed_in_body() {
  printf '%s\n' "const signedIn = test.extend({
  $1: [
    async ({playwright, baseURL}, use) => {
      const context = await playwright.request.newContext({baseURL, storageState: 'state.json'});
      await use(context);
      await context.dispose();
    },
    {scope: 'worker'},
  ],
});

signedIn('every past order is listed newest first', async ({$1}) => {
  const response = await $1.get('/orders');
  expect(response.status()).toBe(200);
});"
}

@test "a signed-in request-context fixture passes the floor and the no-page check" {
  prepare real-server "$(signed_in_body signedInRequest)"
  gate --phase 1 --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 0 ]
}

@test "a request-context fixture named apiContext passes too: no name-suffix rule" {
  prepare real-server "$(signed_in_body apiContext)"
  gate --phase 1 --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 0 ]
}

# --- Prerequisite ---

@test "a detector that exits 3 makes a real-server selection exit 4 naming Node and typescript" {
  prepare real-server "test('every past order is listed newest first', async ({request}) => {
  const response = await request.get('/orders');
  expect(response.status()).toBe(200);
});"
  mkdir -p "$BATS_TEST_TMPDIR/stub"
  printf '#!/bin/sh\nexit 3\n' >"$BATS_TEST_TMPDIR/stub/node"
  chmod +x "$BATS_TEST_TMPDIR/stub/node"
  run bash -c "cd '$WORK' && PATH='$BATS_TEST_TMPDIR/stub':\"\$PATH\" bash '$GATE' '$SPEC' --routing '$ROUTING' --phase 1 --report '$REPORTS/passed-two-files.json' 2>'$STDERR_FILE'"
  [ "$status" -eq 4 ] || return 1
  stderr_has Node typescript
}

@test "with node absent from PATH a real-server selection exits 4 naming Node" {
  prepare real-server "test('every past order is listed newest first', async ({request}) => {
  const response = await request.get('/orders');
  expect(response.status()).toBe(200);
});"
  # A PATH of symlinks to the tools the gate needs, never node.
  mkdir -p "$BATS_TEST_TMPDIR/nonode"
  local tool resolved
  for tool in awk bash cat cut dirname grep head jq ls mktemp rm sed sort tr uniq wc basename find git xargs printf env expr tail tee date sh mkdir; do
    resolved=$(command -v "$tool" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sfn "$resolved" "$BATS_TEST_TMPDIR/nonode/$tool" ;; esac
  done
  run bash -c "cd '$WORK' && PATH='$BATS_TEST_TMPDIR/nonode' '$BASH' '$GATE' '$SPEC' --routing '$ROUTING' --phase 1 --report '$REPORTS/passed-two-files.json' 2>'$STDERR_FILE'"
  [ "$status" -eq 4 ] || return 1
  stderr_has 'node is not on PATH' 'typescript'
}

# --- Red proof: the guard can fail ---

# install_gate_without_no_page: the fixture repo's harness. Every entry of
# .gaia/scripts/spec is a link to the real file so page-use.mjs realpaths into
# the checkout and resolves typescript, except uat-gate-floor.sh, a copy with
# the no-page call removed.
install_gate_without_no_page() {
  local entry
  mkdir -p "$WORK/.gaia/scripts/spec" "$WORK/.claude/hooks/lib"
  for entry in "$SCRIPTS"/*; do
    ln -sfn "$entry" "$WORK/.gaia/scripts/spec/$(basename "$entry")"
  done
  rm -f "$WORK/.gaia/scripts/spec/uat-gate-floor.sh"
  # shellcheck disable=SC2016
  sed 's#^  node "\$(dirname "\${BASH_SOURCE\[0\]}")/page-use.mjs" "\$1" >/dev/null 2>&1#  true#' "$SCRIPTS/uat-gate-floor.sh" >"$WORK/.gaia/scripts/spec/uat-gate-floor.sh"
  ln -sfn "$REPO_ROOT_REAL/.claude/hooks/lib/gaia-packages.sh" "$WORK/.claude/hooks/lib/gaia-packages.sh"
  ln -sfn "$REPO_ROOT_REAL/.gaia/scripts/machine-local-ref-lib.sh" "$WORK/.gaia/scripts/machine-local-ref-lib.sh"
}

@test "red proof: with the no-page call removed the first shape passes, with the real scripts it is refused" {
  local body="test('every past order is listed newest first', async ({page, request}) => {
  const response = await request.get('/orders');
  await page.goto('/orders');
  expect(response.status()).toBe(200);
});"
  prepare real-server "$body"
  install_gate_without_no_page
  grep -qE '^ *node .*page-use.mjs' "$WORK/.gaia/scripts/spec/uat-gate-floor.sh" && return 1
  GATE_UNDER_TEST="$WORK/.gaia/scripts/spec/uat-gate.sh" gate --phase 1 --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 0 ] || return 1
  stderr_lacks opens-page || return 1
  gate --phase 1 --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 1 ] || return 1
  stderr_has opens-page
}

# --- A browser row and a real-server row in one selection ---

# prepare_mixed: a browser row (phase 2) and a real-server row (phase 3), both
# rendered and given a passing-looking body.
prepare_mixed() {
  local header="$BATS_TEST_TMPDIR/header"
  cat >"$SPEC" <<'SPEC_EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-002
    given: a visitor with items in the cart
    when: they check out as a guest
    then: the confirmation page shows the order number
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
| UAT-002 | browser | 2 | checkout | guest-checkout-confirms-order.spec.ts |
| UAT-003 | real-server | 3 | orders | order-history-lists-orders.spec.ts |
<!-- gaia:uat-routing:end -->
ROUTING_EOF
  (cd "$WORK" && bash "$WRITER" "$SPEC" --routing "$ROUTING" >/dev/null)
  BROWSER_RELATIVE='apps/web/.playwright/e2e/checkout/guest-checkout-confirms-order.spec.ts'
  sed -n '1,/^import /p' "$WORK/$BROWSER_RELATIVE" >"$header"
  {
    cat "$header"
    printf '\n%s\n' "test('the confirmation page shows the order number', async ({page}) => {
  await page.goto('/checkout');
  await expect(page.getByRole('heading')).toBeVisible();
});"
  } >"$WORK/$BROWSER_RELATIVE"
  sed -n '1,/^import /p' "$TARGET" >"$header"
  {
    cat "$header"
    printf '\n%s\n' "test('every past order is listed newest first', async ({request}) => {
  const response = await request.get('/orders');
  expect(response.status()).toBe(200);
});"
  } >"$TARGET"
  rm -f "$header"
}

@test "a browser row and a real-server row gate green on a report with both passed, and are counted as owned" {
  prepare_mixed
  gate --all --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 0 ] || return 1
  [ "$output" != "no owned UAT tests" ]
}

@test "a failed report entry for the real-server file fails the gate naming it, and the browser file ran through the gate too" {
  prepare_mixed
  jq '(.. | objects | select(has("tests") and has("file") and (.file | test("orders"))) | .tests[]) |= (.status = "unexpected" | .results[-1].status = "failed")' "$REPORTS/passed-two-files.json" >"$BATS_TEST_TMPDIR/real-server-failed.json"
  gate --all --report "$BATS_TEST_TMPDIR/real-server-failed.json"
  [ "$status" -eq 1 ] || return 1
  stderr_has "$TARGET_RELATIVE" failed || return 1
  stderr_has "$BROWSER_RELATIVE" && return 1
  gate --all --report "$REPORTS/failed.json"
  [ "$status" -eq 1 ] || return 1
  stderr_has "$BROWSER_RELATIVE" "$TARGET_RELATIVE"
}
