---
paths:
  - '.playwright/**/*'
  - 'playwright.config.*'
---

# Playwright Conventions (real-server and browser)

Contents: File locations; Spec file naming; Real-server HTML check; Selectors, prefer semantic over structural; Waiting, web-first assertions only; Hydration barrier; MSW + real dev server; Worker isolation; Auth / session setup; Locale / language; Parallelism and CI; Accessibility scans.

## File locations

- Config: `playwright.config.ts` (package root)
- Specs: real-server and browser specs live at `.playwright/e2e/<feature>/<flow>.spec.ts`, grouped in feature folders; a flat `.playwright/e2e/*.spec.ts` stays valid for cross-cutting checks. A critical user flow's spec lives at `.playwright/flows/<slug>.spec.ts`, and Playwright collects both folders. The surface, not the path, tells them apart: a real-server spec drives the request fixture and opens no page, a browser spec drives a page
- Shared helpers: `.playwright/utils.ts`; the HTML helper for real-server checks is `.playwright/html.ts`
- Output/traces: `.playwright/output/` (gitignored)

## Spec file naming

Match the feature or route: `language-switch.spec.ts`, `things.spec.ts`.
One journey per user flow: one browser journey file per flow, inside its feature folder and named for the behavior (`.playwright/e2e/<feature>/<flow>.spec.ts`, or `.playwright/flows/<slug>.spec.ts` for a critical flow); one `test.describe` block per scenario group. Which behavior gets a test, at which layer, and which capabilities earn a browser spec, including the flow-test and native-form-post rules: `.claude/doctrine/testing.md`. Committed tests follow that file; the vendored test-generation guide in `playwright-cli` does not apply to them.

## Real-server HTML check

A real-server test, for a requirement that the served HTML itself carries (`.claude/doctrine/testing.md`, `## Served HTML`), reads the server's rendered HTML through the request fixture and parses the body with the helper in `.playwright/html.ts`. It opens no page and makes no browser round trip. The helper returns nodes; the test file holds every `expect(`.

```ts
import {expect, test} from '@playwright/test';
import {parseHtml} from '../../html';

test('home page serves its title and description', async ({request}) => {
  const response = await request.get('/');
  expect(response.status()).toBe(200);
  const root = parseHtml(await response.text());
  expect(root.querySelector('title')?.text).toBe('Welcome');
  expect(root.querySelector('meta[name="description"]')).not.toBeNull();
});
```

A form post follows the same shape: get the page, parse it, select the form and post a body `serializeForm` builds from it. A body built from the served form catches a renamed field, a changed hidden intent or a moved default option.

```ts
import {expect, test} from '@playwright/test';
import {parseHtml, serializeForm} from '../../html';

test('the sign-up form redirects on success', async ({request}) => {
  const page = await request.get('/sign-up');
  const form = parseHtml(await page.text()).querySelector('form');
  if (!form) throw new Error('no form on the page');
  const response = await request.post('/sign-up', {
    form: serializeForm(form, {overrides: {email: 'new@example.com'}}),
    maxRedirects: 0,
  });
  expect(response.status()).toBe(302);
  expect(response.headers()['location']).toBe('/welcome');
});
```

## Selectors, prefer semantic over structural

Use ARIA roles and accessible names first:

```ts
page.getByRole('button', {name: 'Save'});
page.getByRole('link', {name: 'Create'});
page.getByRole('textbox', {name: 'Name'});
```

Fall back to `page.locator()` with meaningful attributes only when role queries are insufficient:

```ts
page.locator('select', {hasText: 'English'});
```

Do **not** use CSS class selectors or XPath.

## Waiting, web-first assertions only

Wait with web-first `expect` assertions (`expect(locator).toBeVisible()` and the
rest), which retry until timeout, not `page.waitForTimeout`.

## Hydration barrier

React Router SSR renders before JS hydrates. Call the hydration helper
**before** any interaction:

```ts
import {hydration} from '../utils';

await page.goto('/');
await hydration(page); // waits for <meta name="hydrated" content="true">
```

That import is for a flat spec. From a feature folder the helpers are one level further up: `import {hydration} from '../../utils';`.

## MSW + real dev server

E2E tests run against this tree's `pnpm dev` server, on the port
`bash .gaia/scripts/ports.sh` prints; the main checkout (the clone's primary
working directory, on any branch) uses 5173. Playwright
refuses to reuse a server on that port that is not this tree's own. A second
`webServer` serves the built `storybook-static` on this tree's Storybook port for
the Storybook specs (see Accessibility scans). With
`MSW_ENABLED=true` the dev server mocks both browser and SSR requests (wiring in
`wiki/dependencies/MSW.md`), so tests exercise the real route/loader/action stack
with MSW intercepting API calls. No separate mock server is needed for e2e.

With `MSW_SEED=true`, which only the worker server sets (alongside `MSW_ENABLED=true`), the dev server exposes a seed surface over its `@msw/data` store; a Given builder seeds through it (see Worker isolation).

## Worker isolation

Every worker seeds and reads the MSW store of its own server. A serial project is not an accepted way to share one store: it runs the suite on one core. The worker-scoped server fixture and the typed `GivenBuilder` pattern are in `.playwright/fixtures.ts`; read its comment before adding any project that holds state. The stock suite does not request `workerServer`; only `.playwright/e2e/msw-seed/seeded-record-reaches-the-page.spec.ts` starts a server of its own, logging to `seed-fixture-<parallelIndex>-server.log`.

- Setup goes through Given builders, which seed the worker's own store with unique identities; a form's own submission is checked over HTTP with a body `serializeForm` builds from the served page.
- A request-fixture refusal check (what it asserts: `.claude/doctrine/testing.md`, `## Guards and security rows`) sets `maxRedirects: 0` and states the actor: the request fixture follows redirects by default, is a separate context from `page` and inherits `storageState`.
- This rule governs new setup. An existing suite moves to it only by decision.

## Auth / session setup

When a project has authentication, each worker holds its own session, built in a worker-scoped fixture that logs in against that worker's server and hands the saved storage state to its tests. A single shared login does not work with per-worker stores. An auth-gated real-server test opens no page: the worker-scoped fixture exposes a request context named `signedInRequest`, built with `playwright.request.newContext({baseURL, storageState})` or from a cookie taken from a request-fixture sign-in.

```ts
import {expect, test as base} from '@playwright/test';
import type {APIRequestContext} from '@playwright/test';

export const test = base.extend<object, {signedInRequest: APIRequestContext}>({
  signedInRequest: [
    async ({playwright}, use, workerInfo) => {
      const context = await playwright.request.newContext({
        baseURL: workerInfo.project.use.baseURL,
        storageState: '.playwright/output/signed-in.json',
      });
      await use(context);
      await context.dispose();
    },
    {scope: 'worker'},
  ],
});

test('the account page serves its heading', async ({signedInRequest}) => {
  const response = await signedInRequest.get('/account');
  expect(response.status()).toBe(200);
});
```

Clear cookies explicitly in tests that must start unauthenticated:

```ts
await page.context().clearCookies();
```

## Locale / language

Set locale and Accept-Language headers at the test level, not globally:

```ts
test.use({locale: 'ja'});
// …
await page.setExtraHTTPHeaders({'Accept-Language': 'ja'});
```

## Parallelism and CI

Chromium only by default. Every Playwright run needs Chromium installed, real-server tests included: a real-server test opens no page, but the config's global setup launches Chromium to warm the server. Setting the `TEST_ALL_BROWSERS` constant in `playwright.config.ts` to `true` adds webkit, firefox and mobile locally; CI stays on Chromium. Workers, retries and `forbidOnly` are in the config.

## Accessibility scans

The Storybook specs (`storybook-a11y.spec.ts`, `storybook-focus.spec.ts`) run against `storybook-static`: `storybook-a11y.spec.ts` only checks that the built index matches the story exports in source, and `storybook-focus.spec.ts` checks focus visibility in light and dark. `pnpm pw` and `pnpm pw-ui` build Storybook before Playwright starts, as CI does, so the Storybook specs never read a stale build, and a failed build stops the run before any spec starts; a direct `playwright test` needs `pnpm build-storybook` first. The story server starts even with no build so the other specs run; the story spec fails, never skips, naming `pnpm build-storybook` when `storybook-static/index.json` is missing or its story count differs from the story exports in source. Axe over every story is not run here: the Vitest `storybook` and `storybook-dark` projects run addon-a11y on every story in light and dark, failing on any impact.

Use `expectNoSeriousA11yViolations` from `.playwright/a11y.ts` for axe-core
scans of fully-rendered pages. The fixture in `.playwright/fixtures.ts`
exposes `makeAxeBuilder` for tests that need to customize tags, includes, or
disabled rules. Failure threshold is frozen: critical + serious violations
fail the test; moderate + minor violations attach as `axe-advisory.json` and
emit `console.warn`. Before scanning, the helper waits up to 10 seconds for
every finite animation and transition (`document.getAnimations()`) to finish,
so a theme switch is judged on its settled colors; a longer one is scanned
mid-animation.

```ts
import {test} from '../fixtures';
import {expectNoSeriousA11yViolations} from '../a11y';
import {hydration} from '../utils';

test('home page has no serious a11y violations', async ({page}, testInfo) => {
  await page.goto('/');
  await hydration(page);
  await expectNoSeriousA11yViolations(page, testInfo);
});
```
