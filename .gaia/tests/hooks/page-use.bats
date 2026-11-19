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
  run node "$DETECTOR" "$SPEC_FILE"
  [ "$status" -eq "${2:-1}" ] || { echo "case $1: status=$status output=$output"; return 1; }
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

@test "a page, browser or context fixture use is classified with its reason: page-goto, helper, browser.newPage, in-file project fixture, axe fixture, context.request, hook, chromium import, plain parameter" {
  detect page-goto <<'SRC'
import {test} from '@playwright/test';
test('x', async ({page}) => {
  await page.goto('/');
});
SRC
  assert_reason page-fixture || { echo "case page-goto"; return 1; }
  detect helper <<'SRC'
import {test} from '@playwright/test';
import {openHome} from './helpers';
test('x', async ({page}) => {
  await openHome(page);
});
SRC
  assert_reason page-fixture || { echo "case helper"; return 1; }
  detect browser-new-page <<'SRC'
import {test} from '@playwright/test';
test('x', async ({browser}) => {
  const opened = await browser.newPage();
  await opened.goto('/');
});
SRC
  assert_reason page-fixture || { echo "case browser-new-page"; return 1; }
  assert_reason new-page || { echo "case browser-new-page"; return 1; }
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
  assert_reason project-page-fixture || { echo "case project-fixture"; return 1; }
  assert_reason page-fixture || { echo "case project-fixture"; return 1; }
  detect axe <<'SRC'
import {test} from '../fixtures';
test('x', async ({makeAxeBuilder}) => {
  await makeAxeBuilder().analyze();
});
SRC
  assert_reason project-page-fixture || { echo "case axe"; return 1; }
  detect context-request <<'SRC'
import {test} from '@playwright/test';
test('x', async ({context}) => {
  await context.request.post('/');
});
SRC
  assert_reason page-fixture || { echo "case context-request"; return 1; }
  assert_reason context-request || { echo "case context-request"; return 1; }
  detect hook <<'SRC'
import {test} from '@playwright/test';
test.beforeEach(async ({page}) => {
  await page.goto('/');
});
SRC
  assert_reason page-fixture || { echo "case hook"; return 1; }
  detect browser-import <<'SRC'
import {chromium} from '@playwright/test';
export const launcher = chromium;
SRC
  assert_reason browser-import || { echo "case browser-import"; return 1; }
  detect plain-parameter <<'SRC'
import {test} from '@playwright/test';
test('x', async (fixtures) => fixtures.page.goto('/'));
SRC
  assert_reason page-fixture || { echo "case plain-parameter"; return 1; }
}

@test "request-only specs are clean: page, browser and context in strings and comments, request.newContext, worker fixture, signed-in request, Context-suffixed fixture, request-backed sibling fixture" {
  detect words 0 <<'SRC'
import {expect, test} from '@playwright/test';
test('the page responds', async ({request}) => {
  // opens no page, no browser, no context
  const r = await request.get('/page');
  expect(r.status()).toBe(200);
});
SRC
  [ -z "$output" ] || { echo "case words"; return 1; }
  detect api-context 0 <<'SRC'
import {test} from '@playwright/test';
test('x', async ({request}) => {
  const api = await request.newContext();
  await api.get('/');
});
SRC
  [ -z "$output" ] || { echo "case api-context"; return 1; }
  detect worker-fixture 0 <<'SRC'
import {test as base} from '@playwright/test';
export const test = base.extend({
  api: [async ({playwright, baseURL}, use) => {
    await use(await playwright.request.newContext({baseURL}));
  }, {scope: 'worker'}],
});
SRC
  [ -z "$output" ] || { echo "case worker-fixture"; return 1; }
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
  [ -z "$output" ] || { echo "case signed-in"; return 1; }
  detect suffix 0 <<'SRC'
import {test} from '@playwright/test';
test('x', async ({apiContext}) => {
  await apiContext.get('/');
});
SRC
  [ -z "$output" ] || { echo "case suffix"; return 1; }
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
  [ -z "$output" ] || { echo "case cross-module-request"; return 1; }
}

# module <name>: write stdin to $BATS_TEST_TMPDIR/<name>.ts, a sibling the
# spec written by detect imports through a relative path.
module() {
  cat >"$BATS_TEST_TMPDIR/$1.ts"
}

@test "page-backed fixtures are followed through sibling modules: cross-module, layered, import cycle, diamond; an unresolvable import keeps the one-file verdict" {
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
  [ "$output" = "${SPEC_FILE}${TAB}2${TAB}x${TAB}project-page-fixture" ] || { echo "case cross-module"; return 1; }
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
  assert_reason project-page-fixture || { echo "case layered"; return 1; }
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
  assert_reason project-page-fixture || { echo "case cycle"; return 1; }
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
  assert_reason project-page-fixture || { echo "case diamond"; return 1; }
  detect unresolvable 0 <<'SRC'
import {test} from './missing-fixtures';
test('x', async ({signedInPage}) => {
  await signedInPage.goto('/');
});
SRC
  [ -z "$output" ] || { echo "case unresolvable"; return 1; }
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

@test "a use prints file, line, title and reason tab-separated: static title, and - for a hook" {
  detect exact-line <<'SRC'
import {test} from '@playwright/test';

test('opens home', async ({page}) => {
  await page.goto('/');
});
SRC
  [ "$output" = "${SPEC_FILE}${TAB}3${TAB}opens home${TAB}page-fixture" ] || { echo "case exact-line"; return 1; }
  detect dash-title <<'SRC'
import {test} from '@playwright/test';
test.beforeEach(async ({page}) => {});
SRC
  [ "$output" = "${SPEC_FILE}${TAB}2${TAB}-${TAB}page-fixture" ] || { echo "case dash-title"; return 1; }
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

@test "the template page-status test opens no page, is request-only, holds 200, parses HTML and compares the h1 with the site name heading" {
  run template_opens_no_page "$TEMPLATE_SPEC"
  [ "$status" -eq 0 ] || { echo "case opens-no-page: status=$status output=$output"; return 1; }
  [ -z "$output" ] || { echo "case opens-no-page: output=$output"; return 1; }
  template_status_check "$TEMPLATE_SPEC" || { echo "case status-check"; return 1; }
  template_heading_check "$TEMPLATE_SPEC" || { echo "case heading-check"; return 1; }
}
