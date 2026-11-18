---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-28
tags: [concept, a11y]
---

# Accessibility

## Static lint

`eslint-plugin-jsx-a11y` (included via the Airbnb ESLint config in [[gaia-lint]]) catches accessibility issues at development time. Runs as part of `pnpm lint`.

## Runtime testing

Static lint cannot catch violations that only exist in rendered output (color contrast, computed accessible names). Two axe-core runs cover that gap:

- **Storybook, under Vitest** (`@storybook/addon-a11y`): every story is axe-checked in headless Chromium, and axe runs again for each attached `.test()`. The config is `apps/web/.storybook/a11y.ts`, which `apps/web/.storybook/preview.ts` sets as `parameters.a11y`. It runs the WCAG 2.0/2.1 A and AA tags, the same tag set as the Playwright scan, and fails on a violation of **any** impact. That is stricter than the scan's critical-and-serious filter on purpose: a moderate WCAG failure is still a failure, and it is cheapest to fix while the story is being written. Only the `region` rule is disabled, because a story renders a fragment outside the page landmarks. The `storybook-dark` Vitest project runs the same check on every story in the dark theme.
- **Playwright** (`apps/web/.playwright/a11y.ts`, backed by `@axe-core/playwright`): `expectNoSeriousA11yViolations(page, testInfo, options?)` scans the fully rendered page against the WCAG 2.0/2.1 A and AA tags, on the pages the specs visit. Critical and serious violations fail the test; moderate and minor violations attach as `axe-advisory.json` and emit `console.warn`.

See `apps/web/.claude/rules/storybook.md` (Accessibility).

addon-a11y scopes axe to the body, so it cannot see page-level structure on its own. A page story asserts one level-1 heading and one `main` landmark in a `.test()`.

## Cross-references

- [[ESLint Fixes]]: playbook for lint-level violations.
- `apps/web/.claude/skills/a11y-fixes/`: fix playbook for the axe-core runtime violations surfaced by the runs above.
