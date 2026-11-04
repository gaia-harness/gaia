#!/usr/bin/env bats
#
# Suite for .gaia/scripts/spec/page-use.mjs, the one definition of "this
# Playwright file opens a browser page". It pins the reason token each kind of
# use prints, the clean verdict for request-only tests (including request
# contexts named like a page and words in strings and comments), the printed
# line shape, the exit codes, the symlinked invocation, the pageUsesOf export,
# and the static half of the template's page-status check. Every check has a
# red twin: a positive fixture beside a negative one, or a mutated scratch copy.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/page-use.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

bats_require_minimum_version 1.5.0

setup() {
  HOME_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$HOME_ROOT/.gaia/tests/hooks/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  DETECTOR="$HOME_ROOT/.gaia/scripts/spec/page-use.mjs"
  TEMPLATE_SPEC="$HOME_ROOT/apps/web/.playwright/e2e/route-status.spec.ts"
  TAB="$(printf '\t')"
}

# detect <name> [expected-status]: write stdin to $BATS_TEST_TMPDIR/<name>.spec.ts
# and run the CLI on it, expecting exit 1 unless told otherwise.
detect() {
  SPEC_FILE="$BATS_TEST_TMPDIR/$1.spec.ts"
  cat >"$SPEC_FILE"
  run -"${2:-1}" node "$DETECTOR" "$SPEC_FILE"
}

assert_reason() {
  case "$output" in
    *"${TAB}$1"*) ;;
    *) echo "missing reason $1 in: $output" >&2; return 1 ;;
  esac
}

# The template checks, each taking the file so a red twin runs on a mutated copy.
template_opens_no_page() {
  node "$DETECTOR" "$1"
}

template_status_check() {
  grep -q 'async ({request})' "$1" && grep -q 'toBe(200)' "$1" && grep -q 'parseHtml(' "$1"
}

template_heading_check() {
  grep -q "heading: common.meta.siteName, path: '/'" "$1" &&
    grep -q "querySelector('h1')?.text.trim()).toBe(heading)" "$1"
}

@test "a page destructured in a test body is a page-fixture" {
  detect page-goto <<'SRC'
import {test} from '@playwright/test';
test('x', async ({page}) => {
  await page.goto('/');
});
SRC
  assert_reason page-fixture
}

@test "a page opened through an imported helper is a page-fixture" {
  detect helper <<'SRC'
import {test} from '@playwright/test';
import {openHome} from './helpers';
test('x', async ({page}) => {
  await openHome(page);
});
SRC
  assert_reason page-fixture
}

@test "browser.newPage with a browser fixture is page-fixture and new-page" {
  detect browser-new-page <<'SRC'
import {test} from '@playwright/test';
test('x', async ({browser}) => {
  const opened = await browser.newPage();
  await opened.goto('/');
});
SRC
  assert_reason page-fixture
  assert_reason new-page
}

@test "an in-file project page fixture is a project-page-fixture on the test" {
  detect project-fixture <<'SRC'
import {test as base} from '@playwright/test';
const test = base.extend({
  signedInPage: async ({page}, use) => {
    await use(page);
  },
});
test('x', async ({signedInPage}) => {
  await signedInPage.goto('/');
});
SRC
  assert_reason project-page-fixture
  assert_reason page-fixture
}

@test "the template's known page-backed fixture is a project-page-fixture" {
  detect axe <<'SRC'
import {test} from '../fixtures';
test('x', async ({makeAxeBuilder}) => {
  await makeAxeBuilder().analyze();
});
SRC
  assert_reason project-page-fixture
}

@test "context.request with a context fixture is page-fixture and context-request" {
  detect context-request <<'SRC'
import {test} from '@playwright/test';
test('x', async ({context}) => {
  await context.request.post('/');
});
SRC
  assert_reason page-fixture
  assert_reason context-request
}

@test "a hook that destructures page is a page-fixture" {
  detect hook <<'SRC'
import {test} from '@playwright/test';
test.beforeEach(async ({page}) => {
  await page.goto('/');
});
SRC
  assert_reason page-fixture
}

@test "importing chromium from playwright is a browser-import" {
  detect browser-import <<'SRC'
import {chromium} from '@playwright/test';
export const launcher = chromium;
SRC
  assert_reason browser-import
}

@test "a non-destructured first parameter reading .page is a page-fixture" {
  detect plain-parameter <<'SRC'
import {test} from '@playwright/test';
test('x', async (fixtures) => fixtures.page.goto('/'));
SRC
  assert_reason page-fixture
}

@test "a request-only test whose strings and comments say page, browser and context is clean" {
  detect words 0 <<'SRC'
import {expect, test} from '@playwright/test';
test('the page responds', async ({request}) => {
  // opens no page, no browser, no context
  const r = await request.get('/page');
  expect(r.status()).toBe(200);
});
SRC
  [ -z "$output" ]
}

@test "request.newContext as an API context is clean" {
  detect api-context 0 <<'SRC'
import {test} from '@playwright/test';
test('x', async ({request}) => {
  const api = await request.newContext();
  await api.get('/');
});
SRC
  [ -z "$output" ]
}

@test "playwright.request.newContext inside a worker fixture is clean" {
  detect worker-fixture 0 <<'SRC'
import {test as base} from '@playwright/test';
export const test = base.extend({
  api: [async ({playwright, baseURL}, use) => {
    await use(await playwright.request.newContext({baseURL}));
  }, {scope: 'worker'}],
});
SRC
  [ -z "$output" ]
}

@test "the signed-in real-server pattern is clean" {
  detect signed-in 0 <<'SRC'
import {expect, test as base} from '@playwright/test';
const test = base.extend({
  signedInRequest: [async ({playwright}, use) => {
    const api = await playwright.request.newContext({baseURL, storageState});
    await use(api);
    await api.dispose();
  }, {scope: 'worker'}],
});
test('x', async ({signedInRequest}) => {
  const r = await signedInRequest.get('/account');
  expect(r.status()).toBe(200);
});
SRC
  [ -z "$output" ]
}

@test "a request-context fixture with a Context suffix is clean (no name-suffix rule)" {
  detect suffix 0 <<'SRC'
import {test} from '@playwright/test';
test('x', async ({apiContext}) => {
  await apiContext.get('/');
});
SRC
  [ -z "$output" ]
}

# module <name>: write stdin to $BATS_TEST_TMPDIR/<name>.ts, a sibling the
# spec written by detect imports through a relative path.
module() {
  cat >"$BATS_TEST_TMPDIR/$1.ts"
}

@test "a page-backed fixture a sibling module defines is a project-page-fixture" {
  module project-fixtures <<'SRC'
import {test as base} from '@playwright/test';
export const test = base.extend({
  signedInPage: async ({page}, use) => {
    await use(page);
  },
});
SRC
  detect cross-module <<'SRC'
import {test} from './project-fixtures';
test('x', async ({signedInPage}) => {
  await signedInPage.goto('/');
});
SRC
  [ "$output" = "${SPEC_FILE}${TAB}2${TAB}x${TAB}project-page-fixture" ]
}

@test "a page-backed fixture is followed through a fixtures module's own imports" {
  module base-fixtures <<'SRC'
import {test as base} from '@playwright/test';
export const test = base.extend({
  signedInPage: async ({context}, use) => {
    await use(await context.newPage());
  },
});
SRC
  module layered-fixtures <<'SRC'
import {test as base} from './base-fixtures';
export const test = base.extend({
  dashboard: async ({signedInPage}, use) => {
    await use(signedInPage);
  },
});
SRC
  detect layered <<'SRC'
import {test} from './layered-fixtures';
test('x', async ({dashboard}) => {
  await dashboard.goto('/');
});
SRC
  assert_reason project-page-fixture
}

@test "a fixtures import cycle terminates and keeps the page-backed verdict" {
  module cycle-a <<'SRC'
import {test as base} from './cycle-b';
export const test = base.extend({
  signedInPage: async ({page}, use) => {
    await use(page);
  },
});
SRC
  module cycle-b <<'SRC'
import {test as base} from './cycle-a';
export const test = base.extend({
  other: async ({request}, use) => {
    await use(request);
  },
});
SRC
  detect cycle <<'SRC'
import {test} from './cycle-a';
test('x', async ({signedInPage}) => {
  await signedInPage.goto('/');
});
SRC
  assert_reason project-page-fixture
}

@test "a fixtures module two imports reach counts for both" {
  module shared-fixtures <<'SRC'
import {test as base} from '@playwright/test';
export const test = base.extend({
  signedInPage: async ({page}, use) => {
    await use(page);
  },
});
SRC
  module first-layer <<'SRC'
import {test as base} from './shared-fixtures';
export const test = base.extend({
  other: async ({request}, use) => {
    await use(request);
  },
});
SRC
  module second-layer <<'SRC'
import {test as base} from './shared-fixtures';
export const test = base.extend({
  dashboard: async ({signedInPage}, use) => {
    await use(signedInPage);
  },
});
SRC
  detect diamond <<'SRC'
import {test as first} from './first-layer';
import {test} from './second-layer';
test('x', async ({dashboard}) => {
  await dashboard.goto('/');
});
SRC
  assert_reason project-page-fixture
}

@test "a request-backed fixture a sibling module defines is clean" {
  module api-fixtures <<'SRC'
import {test as base} from '@playwright/test';
export const test = base.extend({
  apiContext: async ({request}, use) => {
    await use(request);
  },
});
SRC
  detect cross-module-request 0 <<'SRC'
import {test} from './api-fixtures';
test('x', async ({apiContext}) => {
  await apiContext.get('/');
});
SRC
  [ -z "$output" ]
}

@test "an unresolvable fixtures import keeps the one-file verdict" {
  detect unresolvable 0 <<'SRC'
import {test} from './missing-fixtures';
test('x', async ({signedInPage}) => {
  await signedInPage.goto('/');
});
SRC
  [ -z "$output" ]
}

@test "pageUsesOf resolves imports against the file path it is handed" {
  mkdir -p "$BATS_TEST_TMPDIR/root/e2e"
  cat >"$BATS_TEST_TMPDIR/root/e2e/fixtures.ts" <<'SRC'
import {test as base} from '@playwright/test';
export const test = base.extend({
  signedInPage: async ({page}, use) => {
    await use(page);
  },
});
SRC
  cat >"$BATS_TEST_TMPDIR/root/e2e/x.spec.ts" <<'SRC'
import {test} from './fixtures';
test('x', async ({signedInPage}) => {
  await signedInPage.goto('/');
});
SRC
  cd "$BATS_TEST_TMPDIR"
  run node --input-type=module -e "
    import {createRequire} from 'node:module';
    import {readFileSync} from 'node:fs';
    import {pageUsesOf} from '$DETECTOR';
    const ts = createRequire('$DETECTOR')('typescript');
    const file = 'e2e/x.spec.ts';
    const sourceFile = ts.createSourceFile(file, readFileSync('root/' + file, 'utf8'), ts.ScriptTarget.Latest, true);
    console.log(pageUsesOf(ts, sourceFile).length, pageUsesOf(ts, sourceFile, 'root/' + file).length);
  "
  [ "$status" -eq 0 ]
  [ "$output" = "0 1" ]
}

@test "a use prints file, line, static title and reason separated by tabs" {
  detect exact-line <<'SRC'
import {test} from '@playwright/test';

test('opens home', async ({page}) => {
  await page.goto('/');
});
SRC
  [ "$output" = "${SPEC_FILE}${TAB}3${TAB}opens home${TAB}page-fixture" ]
}

@test "a hook use prints - for the title" {
  detect dash-title <<'SRC'
import {test} from '@playwright/test';
test.beforeEach(async ({page}) => {});
SRC
  [ "$output" = "${SPEC_FILE}${TAB}2${TAB}-${TAB}page-fixture" ]
}

@test "no argument exits 2" {
  run -2 node "$DETECTOR"
}

@test "a missing file exits 3 and names page-use on stderr" {
  run -3 --separate-stderr node "$DETECTOR" "$BATS_TEST_TMPDIR/absent.spec.ts"
  case "$stderr" in
    page-use:*) ;;
    *) echo "stderr: $stderr" >&2; return 1 ;;
  esac
}

@test "the CLI runs through a symlinked scripts directory" {
  mkdir -p "$BATS_TEST_TMPDIR/linked"
  ln -sfn "$HOME_ROOT/.gaia/scripts/spec" "$BATS_TEST_TMPDIR/linked/spec"
  SPEC_FILE="$BATS_TEST_TMPDIR/symlinked.spec.ts"
  printf "import {test} from '@playwright/test';\ntest('x', async ({page}) => {});\n" >"$SPEC_FILE"
  run -1 node "$BATS_TEST_TMPDIR/linked/spec/page-use.mjs" "$SPEC_FILE"
  assert_reason page-fixture
}

@test "pageUsesOf is importable without running the CLI" {
  run -0 node --input-type=module -e "
    import {createRequire} from 'node:module';
    const ts = createRequire('$HOME_ROOT/.gaia/scripts/spec/page-use.mjs')('typescript');
    const {pageUsesOf} = await import('$DETECTOR');
    const source = ts.createSourceFile('x.spec.ts', \"test('t', async ({page}) => {});\", ts.ScriptTarget.Latest, true);
    console.log(JSON.stringify(pageUsesOf(ts, source)));
  "
  [ "$output" = '[{"line":1,"reason":"page-fixture","test":"t"}]' ]
}

@test "the template page-status test opens no page" {
  run -0 template_opens_no_page "$TEMPLATE_SPEC"
  [ -z "$output" ]
}

@test "the template page-status test is request-only, holds 200 and parses HTML" {
  template_status_check "$TEMPLATE_SPEC"
}

@test "the template compares the parsed h1 with the site name heading" {
  template_heading_check "$TEMPLATE_SPEC"
}

@test "red twin: a template copy destructuring page makes the detector exit 1" {
  copy="$BATS_TEST_TMPDIR/route-status-page.spec.ts"
  sed 's/async ({request}) => {/async ({page}) => {/' "$TEMPLATE_SPEC" >"$copy"
  run -1 template_opens_no_page "$copy"
  assert_reason page-fixture
}

@test "red twin: a template copy asserting 201 fails the status check" {
  copy="$BATS_TEST_TMPDIR/route-status-201.spec.ts"
  sed 's/toBe(200)/toBe(201)/' "$TEMPLATE_SPEC" >"$copy"
  run ! template_status_check "$copy"
}

@test "red twin: a template copy with a different heading fails the heading check" {
  copy="$BATS_TEST_TMPDIR/route-status-heading.spec.ts"
  sed "s/heading: common.meta.siteName/heading: 'Other'/" "$TEMPLATE_SPEC" >"$copy"
  run ! template_heading_check "$copy"
}
