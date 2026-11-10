---
type: module
path: apps/web/test/, apps/web/.playwright/
status: active
language: typescript
purpose: Five-layer testing setup: unit, stories as component tests, route tests, Playwright (real-server and browser), visual regression
depends_on:
  - '[[Vitest]]'
  - '[[Storybook]]'
  - '[[Playwright]]'
  - '[[Chromatic]]'
  - '[[MSW]]'
created: 2026-04-20
updated: 2026-11-07
tags: [module, testing]
---

# Testing

Testing has **five layers**, all sharing a common [[MSW Handlers|MSW]] mocking layer:

- Unit: [[Vitest]] in `apps/web/app/utils/tests/` (pure and server code), and `vitest-browser-react` tests for hooks
- Component and page: Storybook stories with `.test()` behaviors in `apps/web/app/components/*/tests/`, `apps/web/app/pages/*/tests/`, run by Vitest through `@storybook/addon-vitest`
- Route: Vitest `node` tests in `apps/web/app/route-tests/<feature>/tests/` that call a route module's `loader` or `action` with a `Request`
- Playwright: [[Playwright]] in `apps/web/.playwright/e2e/` and `apps/web/.playwright/flows/`, on two surfaces, real-server (request fixture, no page) and browser (a real page); [[Test Layering]] owns which proves what
- Visual regression: [[Chromatic]] (CI only), driven by the same stories

A story is the component test and the visual-regression input, so both share one source of truth. A page's rendered states are page stories, which mount the route's exports through `stubs.reactRouter` and drive MSW handlers. A route module's status, redirect, returned data, validation error, authorization outcome or side effect is a route test. [[Test Layering]] owns which layer proves what. See [[Stories as Tests]] and [[Component Testing]].

Server-side tests (the QueryClient accessor, `attempt`, base-URL resolution) run in the `node` Vitest project against the MSW node server.

## Vitest

One config, `apps/web/vitest.config.ts`, defines the projects: `node` for pure and server code, `browser` for hooks and any `*.test.tsx`, `storybook` for every story, and `storybook-dark` for the same stories in the dark theme. Read it for the exact membership. The `browser` and storybook projects run in headless Chromium; no project uses an emulated DOM.

> [!info] Watch mode needs a TTY
> Vitest only enters watch mode with an interactive TTY; in CI or under Claude, a bare `pnpm test` runs once and exits. Use `pnpm test --run` for an explicit single pass. See [[Vitest]].

### Setup prerequisite

Vitest's browser projects need Chromium, and `pnpm install` installs no browsers. `/gaia-init` and `/setup-gaia` install Chromium alone (`playwright install chromium`, no OS dependencies, so no `sudo`). `pnpm install:browsers` installs every Playwright browser with its OS dependencies, which local `pnpm pw` uses too; run it once per machine outside those commands. A missing browser fails the run with an install command rather than skipping the tests.

### Accessibility coverage

`@storybook/addon-a11y` axe-checks every story under Vitest, in the light theme (`storybook`) and again in dark (`storybook-dark`), so `pnpm test` checks a theme or token change. See [[Accessibility]].

## Component test pattern

Test a component or page with a story that carries `.test()` blocks for its behaviors, at most one per behavior. Never manually mock framework deps (`react-router`, `react-i18next`, etc.); use the stubs. Mock only external services or utilities the component imports directly. See [[Stories as Tests]] and [[Component Testing]] for the canonical pattern.

## Playwright

- Real-server and browser tests in `apps/web/.playwright/e2e/` and `apps/web/.playwright/flows/<slug>.spec.ts`, config in `apps/web/playwright.config.ts`
- Use the bundled `hydration(page)` helper after `page.goto()` to wait for React Router hydration before interacting

### a11y scanning

The shipped specs live in `apps/web/.playwright/e2e/`; critical-flow specs go in `apps/web/.playwright/flows/`. `apps/web/.playwright/a11y.ts` exports `expectNoSeriousA11yViolations(page, testInfo, options?)`: critical and serious violations fail the test; moderate and minor violations attach as an `axe-advisory.json` and surface via `console.warn`. `apps/web/.playwright/fixtures.ts` exposes the `makeAxeBuilder` fixture (WCAG 2.0/2.1 A and AA tags) for custom scans.

### Cold-start hydration self-heal

`apps/web/playwright.config.ts` wires `globalSetup: './.playwright/global-setup.ts'`, a serial `/` navigation that warms Vite's cold dep-optimize cache before the parallel specs run. Local retries are 0 (2 on CI) by design, so the `hydration(page)` helper's probe-then-reload self-heals the cold dep-optimize race rather than masking real flakes. The first `pnpm pw` after a dependency or Vite-config change boots a cold cache and can lose the race on the dynamic import of `entry.client.tsx`.

## Chromatic

- Visual regression in CI; gating and token in [[Chromatic#CI gating]]
- To remove it, see the Opt-out section of [[Chromatic]]

## ESLint rules on test files

Test files are linted by the `testing` preset of [[gaia-lint]] and stories by its `storybook` preset. See [[ESLint Fixes]] for fix patterns.

## Pre-commit

The pre-commit hook runs `pnpm typecheck`, `pnpm exec lint-staged` (eslint, prettier, stylelint), then `pnpm test:lint-staged` (`vitest --run --changed --passWithNoTests --bail 1`) as a separate step, so only tests affected by the staged changes run (browser projects included, so Chromium must be installed). See [[Quality Gate]].

For the current folder inventory and helper signatures, list `apps/web/test/`.
