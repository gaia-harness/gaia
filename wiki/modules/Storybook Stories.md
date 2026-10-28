---
type: module
path: frontend/.storybook/
status: active
language: typescript
purpose: Storybook setup with React Router, i18n, dark mode, and Chromatic snapshots
depends_on:
  - '[[Storybook]]'
  - '[[MSW]]'
created: 2026-04-20
updated: 2026-10-28
tags: [module, storybook, testing]
---

# Storybook Stories

Storybook v10 with the `@storybook/react-vite` framework. Configured to discover `*.stories.tsx` anywhere in `frontend/app/`. Stories are written in CSF Next (CSF4): each file imports the preview as `import preview from '#.storybook/preview'`, builds its meta with `preview.meta({...})`, and declares stories with `meta.story({...})`, `.extend({...})` and `.test()`. `.storybook/main.ts` turns on `features.experimentalTestSyntax`, and `.storybook/preview.ts` is a `definePreview` call that wires the addons.

## Why Storybook is also the test driver

`@storybook/addon-vitest` runs every story as a Vitest test in headless Chromium, and a behavior is a `.test()` attached to a story (a story's `play` only drives the UI into the state its snapshot shows), so one source of truth drives the component test, visual regression (Chromatic) and the Playwright story scan. `@storybook/addon-a11y` axe-checks each story. See [[Stories as Tests]], [[Component Testing]] and [[Testing]].

## Decorator stack: the load-bearing convention

Innermost to outermost (array order in `.storybook/chromatic/index.ts`): **`WrapDecorator → ChromaticDecorator → ToastDecorator`**.

- `WrapDecorator`: reads `parameters.wrap` and wraps the story (use `parameters: {wrap: 'p-4'}` for padding instead of hardcoding divs in stories)
- `ChromaticDecorator`: Chromatic snapshots only; renders the story once, puts `dark` on `<html>` when the `theme` global is `dark`, and clears `sessionStorage` before each snapshot
- `ToastDecorator`: renders a bare `<Toaster />` from `~/components/ui/toast` after every story except one that sets `parameters.toaster: false`, so a toast call from any other story is rendered

Interactive sessions skip the Chromatic decorator: `WrapDecorator → ToastDecorator`.

## Stubs

`frontend/test/stubs/` provides story-level decorators (`stubs.state()`, `stubs.reactRouter()`). Apply as `[stubs.state(), stubs.reactRouter()]` when both are needed. `stubs.reactRouter` binds one route, and its `route` option accepts the client-side exports (`clientLoader`, `clientAction`, `HydrateFallback`) as well as `loader` and `action`. See `frontend/.claude/rules/storybook.md` for the full option list.

## Dark-mode handling

`preview.ts` sets `darkClass` and `lightClass` to the `dark` or `light` class plus the role-token utilities `bg-background` and `text-foreground`, applied to the preview document root when the toolbar toggle fires, so the `.dark` token block in `theme.css` drives both themes. `stylePreview: true` extends the theme to Storybook chrome.

Chromatic loads only the preview iframe, so the toolbar toggle never fires there. Instead `frontend/.storybook/modes.ts` defines a `light` and a `dark` [[Chromatic]] mode, each setting the `theme` global (declared in `preview.ts` `initialGlobals`, since Storybook drops an undeclared global) and the 1280px viewport. Chromatic snapshots every story once per mode, and `ChromaticDecorator` applies the global. Vitest and the Playwright scan never add that decorator, so `theme` changes nothing there.

## i18n in stories

`storybook-react-i18next` is wired to the project's own `~/i18n` config. Toolbar exposes the configured locales. Inside story functions, call `useTranslation()` normally; no extra setup. Per-locale content variation (e.g. stress-testing long CJK strings) is handled inside the story by reading `i18n.language`. A preview loader awaits `changeLanguage` to the story's locale before render, so a built Storybook shows the selected locale in a `play` and in a `.test()`. The i18next addon is wired in `definePreview`'s `addons` through `definePreviewAddon<AddonTypes>(storybookReactI18next)`. The initial locale and the Storybook i18next init both read `DEFAULT_LOCALE`.

## Test data: MSW

`msw-storybook-addon` is wired: `.storybook/main.ts` serves `public/` as a static directory (so built Storybook and Chromatic find `mockServiceWorker.js`), and `.storybook/preview.ts` lists `addonMsw()` in `definePreview`'s `addons`. A story installs handlers in its `beforeEach` through the addon's CSF Next API. Handlers read a mutation body with `request.json()`. Seed data comes from the `@msw/data` collections in `frontend/test/mocks/database`. See `frontend/.claude/rules/storybook.md` for the usage pattern, [[Stories as Tests]] for the doctrine, and [[MSW Handlers]] for the handler structure.

When TanStack Query is on, a Storybook decorator (`.storybook/decorators/query-client-decorator.tsx`) gives each story a fresh QueryClient. See [[Data Loading]].

For the current file inventory, list `frontend/.storybook/`.
