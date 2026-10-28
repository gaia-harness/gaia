---
type: decision
status: active
priority: 1
date: 2026-10-05
created: 2026-10-05
updated: 2026-10-28
tags: [decision, testing, storybook, vitest, a11y, csf4]
---

# Decision: Stories Are the Component Tests

A story is a visual state. A behavior is a `.test()` attached to that story. A play function only drives the UI into the state the snapshot must show, and asserts nothing. Components and pages are tested this way, run by `@storybook/addon-vitest` in headless Chromium. No test file re-composes a story, and no DOM is emulated anywhere in the frontend: the browser projects run real Chromium and the `node` project has no DOM at all.

This page owns the doctrine. Every other page that teaches stories states it in one sentence and links here.

## Rationale

- Each snapshot means one thing. A story that is also a pile of assertions snapshots a state nobody chose; a story that only sets up a state is a clean Chromatic baseline.
- Each behavior is a named, separately reported test. A failing `.test()` names the behavior that broke in the Vitest and Storybook UI reports, where a failing `play` reports one opaque story.
- One artifact. The story carries the decorators, stubs, i18n and seed data the component needs, so the same file feeds Storybook, Chromatic, the Playwright story scan and the Vitest run. A separate test file that re-composes the story duplicates that wiring and lets the two drift.
- Real browser. Layout, focus, pointer and keyboard behavior, and axe contrast checks run in Chromium, not in an emulation that approximates it.
- Every story and every attached test is axe-checked by `@storybook/addon-a11y`. See [[Accessibility]].

## The CSF4 shape

Stories are CSF Next (CSF4) only, with `features.experimentalTestSyntax` on in `frontend/.storybook/main.ts`. Story files import the preview through the `#.storybook/preview` subpath and build everything from it.

```tsx
import preview from '#.storybook/preview';

const meta = preview.meta({component: Button});

export const Default = meta.story({args: {label: 'Save'}});

export const Disabled = Default.extend({args: {disabled: true}});

Default.test('calls onClick when pressed', async ({canvas, args, userEvent}) => {
  await userEvent.click(canvas.getByRole('button', {name: 'Save'}));
  await expect(args.onClick).toHaveBeenCalledOnce();
});
```

Each export is a direct `meta.story({...})` or `.extend({...})` call; a story built by a factory function is not supported, because Storybook's indexer cannot attach `.test()` to it. A `play` may click, type or open, to reach a state; it never calls `expect`. msw handlers install in the story's `beforeEach`, never `parameters.msw`. `frontend/.claude/rules/storybook.md` owns the authoring rules.

## How `.test()` runs

- A story with any `.test()` becomes a describe block named for the story. Its own render is a test named `base story`, and each attached test is a sibling named for its string.
- Before each test the story's loaders run, then its `play`, so a test starts in the visual state the snapshot shows.
- Axe runs for the base story and for each attached test.
- A story with no tests and a `play` runs as a single test; a render-only story runs as a render and an axe check.
- A story tagged `!test` (story or meta level) is skipped by the Vitest run and the harness alike.

## What counts as a test to the harness

`.gaia/scripts/red-ledger/extract-story-signals.mjs` names each story and each `.test()` the way the reporter does (its header owns the exact names, the signal regions and the refusal list), so the [[Worthiness Presence Gate]] and the [[Worthiness Audit]] see one identity per base story and one per attached test. The harness does not count a render-only story with no tests.

## Where the format is enforced

- The extractor reads CSF4 only. An old-format story file makes `extract-test-signals.mjs` exit 8 and print the migration command; a shape it cannot resolve exits 7. The worthiness presence gate denies on both with the file and the extractor's one-line reason.
- `gaia migrate-csf4` converts an old-format package, repairs the preview and main, and verifies each story file. See [[GAIA CLI]].
- The quick audit classifier routes a story file that is not CSF4 on either side of a diff to the deep audit.

## Classification and gates

- A `*.stories.tsx` classifies **emergent** wherever it sits, before any path or AST check ([[Determinism Classifier]]). Stories are never RED-gated; the [[Worthiness Audit]] judges each test, and the presence gate requires a ledger line per identity the PR changes.
- Hooks stay `*.test.ts` under a `hooks/` folder. They classify by the normal rules, so a deterministic hook keeps the RED demand ([[TDD RED Verification]]).
- When Chromium is missing, the RED capture hook says so and names `pnpm install:browsers` rather than recording nothing silently.

## The three Vitest projects

`frontend/vitest.config.ts` defines three projects; read it for the exact membership instead of a copy here.

- `node`: pure and server code (`*.test.ts` outside hook folders), no DOM, with the MSW node server and the test-data reset in `test/setup.ts`.
- `browser`: hooks (`vitest-browser-react`) and any `*.test.tsx`, in Chromium, with `test/setup.browser.ts`. GAIA supplies no React Testing Library setup, so a test file that imports it brings its own render wrapper and dependencies; converting it to a story is the supported path.
- `storybook`: every story, through `storybookTest` from `@storybook/addon-vitest`. The preview annotations, addon presets included, apply automatically; no setup file in `.storybook/` calls `setProjectAnnotations`, because a file that does switches that automatic provisioning off.

All browser projects need Chromium. See [[Testing]] for the `pnpm install:browsers` prerequisite.

## Conventions

- **shadcn `ui` components** get render-only stories. A `.test()` belongs there only for behavior GAIA adds on top of the vendored component ([[shadcn Component Layer]]).
- **Story-scoped configuration** goes through props, not module state. `LanguageSelect` takes an optional `languages` prop (default: the app's full list), so a story passes the locales it needs without touching the app-wide list.
- **Router stub.** `stubs.reactRouter` (`frontend/test/stubs/react-router-stub.tsx`) accepts `actions` (a per-path action overriding the no-op entry for that path) and `destinations` (paths that render `Navigated to <path>` inside a main landmark so a test asserts arrival by text). The options may be a function of the story context, which lets a decorator read `fn()` spy args.
  - Router stubs do not nest: one `stubs.reactRouter` per story file, at meta level. Per-story variation goes through the function form.
  - An `actions` key must differ from the stub's `path`, because the main route matches first. A form posting to its own route is observed through the `action` option instead.
- **Callback spies.** A story that spies on a prop spreads `{...args}` last, so an `fn()` arg reaches the component. See [[Component Testing]].

See [[Testing]], [[Component Testing]], [[Storybook Stories]], [[Storybook]], [[Vitest]].
