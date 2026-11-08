---
name: remove-i18n
description: Deterministic runbook that strips the entire i18next stack from a GAIA-derived project, packages, source wiring, audit checks, hooks, manifest entries, and wiki pages.
---

# Remove i18n

All paths in this file are repo-relative. The executing agent runs from the project root.

Execute every section in order, top to bottom. No skipping, no reordering. After Section I passes, Section J deletes this file and `add-locale.md`, which no longer apply once i18n is gone.

This runbook takes no variables, i18n removal is identical for every project.

If any verification command in Section I fails, **stop** and report the failure verbatim. Do **not** self-delete.

---

## Section A, Unwrap `useTranslation` / `t()` calls in source

Discover every call site:

```bash
grep -rln "useTranslation\|i18next" apps/web/app apps/web/test
```

For every match in `apps/web/app/` (excluding `apps/web/app/i18n.ts`, `apps/web/app/middleware/i18next.ts`, `apps/web/app/languages/`, `apps/web/app/sessions.server/language.ts`, `apps/web/app/routes/actions.set-language.ts`, `apps/web/app/components/language-select/`, those are deleted in Section C):

1. Open the file.
2. Delete the import line: `import {useTranslation} from 'react-i18next';`
3. Delete the destructure: `const {t} = useTranslation();` (or `useTranslation('namespace')`).
4. Replace every `t('key')` and `t('key', {…})` call with the literal English string from `apps/web/app/languages/en/`. A value that is an i18next nesting reference such as `$t(common:meta.siteName)` is resolved to the string it names (here `meta.siteName` in `common.ts`) before inlining, never copied verbatim.
5. If the file used `<Trans>` from `react-i18next`, replace the JSX with the literal English markup.

The discovery grep above owns the set of files to unwrap. Stories are the component tests, so a `tests/*.stories.tsx` file beside a matched component is a match too, and no `.test.tsx` sits beside it.

Resolve translation keys via the `apps/web/app/languages/en/` files. Example: `t('meta.siteName')` → look up `meta.siteName` in `apps/web/app/languages/en/common.ts` and inline the resolved string.

`useTranslation`/`t()` is not the only i18n coupling on the index page: `apps/web/app/pages/index/page.tsx` also imports and renders `LanguageSelect`, which Section C deletes. In every file that references it, remove the `import LanguageSelect from '~/components/language-select';` line and the `<LanguageSelect />` element. Discover all such files:

```bash
grep -rln "components/language-select" apps/web/app apps/web/test
```

After unwrapping all source files, re-run the grep. If any matches remain in `apps/web/app/` or `apps/web/test/` outside the deletion targets above, unwrap those too. Repeat until the grep prints no file outside them.

---

## Section B, Root + entry files

These files have structural i18n wiring that the regex-style unwrap in Section A does not cover. Apply the diffs below verbatim.

### B1. `apps/web/app/root.tsx`

Remove these imports:

```ts
import {useTranslation} from 'react-i18next';
import {getLanguage, i18nextMiddleware} from '~/middleware/i18next';
import {languageCookie} from '~/sessions.server/language';
```

Delete the middleware export:

```ts
export const middleware = [i18nextMiddleware];
```

Inside the loader, delete:

```ts
const language = getLanguage(context);
```

```ts
headers.append('Set-Cookie', await languageCookie.serialize(language));

headers.set('Vary', 'Cookie');
```

Drop `language` from the loader's returned data object.

In the `App` component, delete:

```ts
const {i18n} = useTranslation();
```

```ts
useEffect(() => {
  void i18n.changeLanguage(language);
}, [i18n, language]);
```

Replace `language` in the destructure with the remaining loader fields (drop `language`).

Replace the `<Document>` props:

```tsx
dir={i18n.dir(i18n.language)}
lang={i18n.language}
```

with:

```tsx
dir = 'ltr';
lang = 'en';
```

### B2. `apps/web/app/entry.client.tsx`

Replace the entire file body with:

```tsx
import {startTransition, StrictMode} from 'react';
import {hydrateRoot} from 'react-dom/client';
import {HydratedRouter} from 'react-router/dom';

const prepareApp = async () => {
  if (import.meta.env.DEV && window.process.env.MSW_ENABLED === true) {
    const [{network}, {default: handlers}] = await Promise.all([
      import('virtual:msw'),
      import('../test/mocks'),
    ]);

    network.configure({
      handlers,
      onUnhandledFrame: 'bypass',
    });
    await network.enable();
  }
};

const hydrate = async () => {
  await prepareApp().then(() => {
    // The react-perf capture harness sets this global (via addInitScript, before
    // hydration) to opt out of StrictMode for honest, non-doubled render
    // timings; everything else keeps StrictMode on.
    // eslint-disable-next-line no-underscore-dangle -- global injected by the react-perf capture harness
    const isStrictModeDisabled = window.__PERF_NO_STRICT;
    startTransition(() => {
      hydrateRoot(
        document,
        isStrictModeDisabled ?
          <HydratedRouter />
        : <StrictMode>
            <HydratedRouter />
          </StrictMode>
      );
    });
  });
};

await hydrate();
```

### B3. `apps/web/app/entry.server.tsx`

Remove these imports:

```ts
import {I18nextProvider} from 'react-i18next';
import {createInstance} from 'i18next';
import i18nConfig from '~/i18n';
import {getInstance} from '~/middleware/i18next';
```

Delete the `i18n` IIFE:

```ts
const i18n = (() => {
  try {
    return getInstance(routerContext);
  } catch {
    // Middleware didn't run (e.g. unmatched routes like Chrome DevTools probes)
    const fallback = createInstance();

    void fallback.init({...i18nConfig, lng: i18nConfig.fallbackLng});

    return fallback;
  }
})();
```

Replace the JSX:

```tsx
<I18nextProvider i18n={i18n}>
  <ServerRouter context={entryContext} nonce={nonce} url={request.url} />
</I18nextProvider>
```

with:

```tsx
<ServerRouter context={entryContext} nonce={nonce} url={request.url} />
```

The `routerContext` parameter is now unused, drop it from the `handleRequest` signature, and drop `RouterContextProvider` from the `import type {EntryContext, RouterContextProvider} from 'react-router'` line.

### B4. `apps/web/app/components/errors/root-error-boundary/index.tsx`

Delete these lines:

```ts
/* eslint-disable i18next/no-literal-string -- renders when i18n may have failed, so its strings stay English */
import {DEFAULT_LOCALE} from '~/i18n';
import errors from '~/languages/en/errors';
```

Replace each `lang={DEFAULT_LOCALE}` with `lang="en"`, replace the `{errors.unexpectedError}` reference with the literal `An unexpected error occurred`, and delete the comment block above `const RootErrorBoundary`, which describes the i18n fallback.

### B5. `apps/web/eslint.config.mjs`

Delete the `...lint.i18n,` line. With no i18next the bundle's `i18n` block reports every JSX string. A project that adds i18n back restores the line.

### B6. `apps/web/app/components/form/conform-field-error/index.tsx`

Its `t(message)` takes a dynamic key, and it imports the language file Section C deletes. Delete both i18n imports (`useTranslation`, `~/languages/en/errors`) and the `useTranslation` call, then copy the `validation` block from `apps/web/app/languages/en/errors.ts` into a local `VALIDATION_MESSAGES` constant typed `Record<string, string>`, and render each error as `{message: VALIDATION_MESSAGES[message] ?? message}`. Delete `ValidationKey` and `isValidationKey`. Then reword that component's docblock, `apps/web/.claude/skills/react-code/references/conform-forms.md` and `wiki/modules/Form Components.md`, where a schema message is a key in `errors.validation` that `ConformFieldError` translates: it becomes a key in `VALIDATION_MESSAGES`.

---

## Section C, Delete files

```bash
rm -rf \
  apps/web/app/i18n.ts \
  apps/web/app/middleware/i18next.ts \
  apps/web/app/types/i18n \
  apps/web/app/languages \
  apps/web/app/sessions.server/language.ts \
  apps/web/app/routes/actions.set-language.ts \
  apps/web/app/components/language-select \
  apps/web/.storybook/i18next.ts \
  apps/web/.playwright/e2e/language-switch-a11y.spec.ts \
  apps/web/.claude/rules/i18n.md \
  apps/web/.claude/agents/code-audit-frontend/react-i18next.md \
  apps/web/.claude/skills/react-code/references/translation-patterns.md \
  wiki/modules/i18n.md \
  "wiki/flows/Language Flow.md" \
  wiki/dependencies/i18next.md \
  wiki/dependencies/remix-i18next.md
```

---

## Section D, Storybook preview, test infra

### D1. `apps/web/.storybook/preview.ts`

Remove:

```ts
import i18n from './i18next';
import {DEFAULT_LOCALE} from '~/i18n';
```

Remove the `locale` and `locales` entries from `initialGlobals`, keeping `theme: 'light'` with its comment:

```ts
locale: DEFAULT_LOCALE,
locales: {
  en: {left: '🇺🇸', right: 'en', title: 'English'},
},
```

Remove the locale-sync loader (the async function that reads `globals.locale` and calls `i18n.changeLanguage`) and its comment from `loaders`; if that leaves `loaders` empty, remove the `loaders` property too. Remove the `i18n` key from `parameters`:

```ts
i18n,
```

Remove the i18next entry from the `addons` array of the `definePreview({...})` call, together with the `eslint-disable-next-line` comment above it:

```ts
definePreviewAddon<AddonTypes>(storybookReactI18next),
```

Then remove its two imports, plus the `// Storybook internal import` comment above them. Keep `import {definePreviewAddon} from 'storybook/internal/csf';` and `import type {AddonTypes} from 'storybook/internal/csf';` only if another `addons` entry still uses `definePreviewAddon` or `AddonTypes`; otherwise remove them too:

```ts
import storybookReactI18next from 'storybook-react-i18next/preview';
import type {AddonTypes} from 'storybook/internal/csf';
import {definePreviewAddon} from 'storybook/internal/csf';
```

Leave `addonMsw()` and the other addons in place.

### D2. `getLanguage` callers

`apps/web/test/utils.ts` carries no i18n code, so it needs no edit. Grep for `getLanguage` across the repo and unwrap any callers (typically loaders/actions in `apps/web/app/routes/`):

```bash
grep -rln "getLanguage" apps/web/app apps/web/test
```

For each caller, drop the import and replace any usage with the literal `'en'`.

### D3. `apps/web/.playwright/e2e/route-status.spec.ts` and `apps/web/app/action-paths.ts`

Delete both set-language tests (`'set-language action redirects and sets the language cookie'` and `'set-language action refuses a redirect target on another host'`, the two that POST to `ACTION_PATHS.setLanguage`) from `apps/web/.playwright/e2e/route-status.spec.ts`, leaving the page-status test.

The page-status test imports `common` from `../../app/languages/en/common` for the expected `/` heading, and Section C deletes that module. Drop the import and replace `common.meta.siteName` in the `PAGES` entry with the resolved string from `meta.siteName` in `apps/web/app/languages/en/common.ts`.

Remove the `setLanguage` key from `ACTION_PATHS` in `apps/web/app/action-paths.ts`:

```ts
setLanguage: '/actions/set-language',
```

`apps/web/test/action-paths.test.ts` iterates `Object.entries(ACTION_PATHS)`, so it needs no edit.

### D4. `apps/web/playwright.config.ts`

Remove the import of the deleted `languages` module:

```ts
import {LANGUAGES} from './app/languages';
```

Remove the `languageCount` constant with its comment:

```ts
// Annotated as number so lint does not read the literal length of an `as const`
// LANGUAGES tuple and flag the testIgnore condition as always true or false.
const languageCount: number = LANGUAGES.length;
```

Remove the `testIgnore` property with its comment:

```ts
// The language switcher renders only with two or more languages, so its spec
// is excluded until a second language is added to LANGUAGES.
testIgnore:
  languageCount < 2 ? ['**/language-switch-a11y.spec.ts'] : undefined,
```

The spec the property gated is deleted in Section C.

### D5. Tooling config that still names the i18n stack

Each file below still references a package Section E removes or a path Section C deletes. Leaving any of them breaks Storybook, the Vitest storybook projects, or `pnpm knip`.

`apps/web/.storybook/main.ts`: remove the addon from `addons`:

```ts
'storybook-react-i18next',
```

`apps/web/vite.config.ts`: remove these entries from `optimizeDeps.include`:

```ts
'accept-language-parser',
'i18next',
'i18next-browser-languagedetector',
'react-i18next',
'remix-i18next',
```

`apps/web/vitest.config.ts`:

- Remove `'i18next',` from the storybook projects' `optimizeDeps.include` (in `createStorybookProject`).
- In `test.coverage.exclude`, change `'app/{languages,routes,sessions.server,state,types}/**/*'` to `'app/{routes,sessions.server,state,types}/**/*'`, and change `'app/{entry.client,entry.server,env.server,i18n,root}.*'` to `'app/{entry.client,entry.server,env.server,root}.*'`.

`apps/web/knip.config.ts`: remove the `'app/languages/index.ts',` entry from `entry`.

`apps/web/test/setup.story-dark.ts`: the language select story is the only member of `RENDERS_NOTHING_BY_DESIGN`. Delete the comment and the set, and drop the set check from `expectStoryHasContent`. An emptied set would fail `pnpm lint` (`sonarjs/no-empty-collection` has no autofix):

```ts
// Stories whose subject renders nothing in this project: the language select
// hides itself in a single-language project.
const RENDERS_NOTHING_BY_DESIGN = new Set([
  'components-languageselect--default',
]);
```

is deleted, and the line

```ts
  if (RENDERS_NOTHING_BY_DESIGN.has(id)) return;
```

in `expectStoryHasContent` is deleted with it, and so is the `rendered no content` message's mention of `RENDERS_NOTHING_BY_DESIGN`.

---

## Section E, package.json

Open `apps/web/package.json` and:

Remove these keys from `dependencies`:

- `i18next`
- `react-i18next`
- `remix-i18next`
- `i18next-browser-languagedetector`

Remove these keys from `devDependencies`:

- `storybook-react-i18next`
- `accept-language-parser`
- `@types/accept-language-parser`

Remove any keys from the `overrides:` map in `pnpm-workspace.yaml` whose name starts with `remix-i18next>` (none may exist if the map is empty, leave it that way).

Then run:

```bash
pnpm install
```

---

## Section F, `.claude/` skills, rules, hooks, agents

### F1. `.claude/agents/code-audit-frontend.md` and `apps/web/.claude/agents/code-audit-frontend/react-buckets.md`

The translation specialist runs only when the scope resolver prints a `translation` line (a changed language file or an i18n call signal), which an app with i18n removed never produces, so `.claude/agents/code-audit-frontend.md` needs no edit.

In `apps/web/.claude/agents/code-audit-frontend/react-buckets.md`, delete the `## Translation (translation)` section and drop `translation` from the `subagents:` frontmatter list.

### F2. `apps/web/.claude/agents/code-audit-frontend/README.md`

Search for any `subagents:` lists and drop `translation` from them.

### F3. `apps/web/.claude/skills/react-code/SKILL.md`

Delete the `### Gate 3: Translation Check` section in its entirety.

In the References list, delete the line referencing `references/translation-patterns.md`.

If there is an "Adding New Keys" section that references `apps/web/app/languages/`, delete that section.

### F4. `apps/web/.claude/skills/new-route/SKILL.md`

In workflow step 1, delete the sentence "Pass `--i18n` whenever the project has i18n (`app/i18n.ts` exists): without it the page carries literal text, which lint (`i18next/no-literal-string`) rejects."

In the front-matter `description`, replace ", page story, and optional i18n keys" with " and page story" (result: "its page component and page story").

### F5. `apps/web/.claude/rules/routes.md`

In the conventions parenthetical, drop `i18n keys, ` (or `, i18n keys` depending on its position).

### F6. `apps/web/.claude/rules/storybook.md`

Delete the `## i18n in stories` section.

---

## Section G, `.gaia/manifest.json`

Remove every key whose path matches any of:

- `apps/web/app/languages/*` (every entry under `apps/web/app/languages/`)
- `apps/web/app/i18n.ts`
- `apps/web/app/middleware/i18next.ts`
- `apps/web/app/types/i18n/*`
- `apps/web/app/sessions.server/language.ts`
- `apps/web/app/routes/actions.set-language.ts`
- `apps/web/app/components/language-select/*`
- `apps/web/.claude/rules/i18n.md`
- `apps/web/.claude/agents/code-audit-frontend/react-i18next.md`
- `apps/web/.claude/skills/react-code/references/translation-patterns.md`
- `apps/web/.storybook/i18next.ts`
- `apps/web/.playwright/e2e/language-switch-a11y.spec.ts`
- `wiki/modules/i18n.md`
- `wiki/flows/Language Flow.md`
- `wiki/dependencies/i18next.md`
- `wiki/dependencies/remix-i18next.md`

A bare edit is blocked by `.claude/hooks/block-manifest-write.sh`, so the removal runs as a marker-carrying Bash write, a `jq` filter dropping the matched keys, written to a temp file and moved into place:

```bash
GAIA_MANIFEST_WRITE=remove-i18n jq '
  .files |= with_entries(
    select(.key
      | test("^apps/web/app/languages/|^apps/web/app/i18n\\.ts$|^apps/web/app/middleware/i18next\\.ts$|^apps/web/app/types/i18n/|^apps/web/app/sessions\\.server/language\\.ts$|^apps/web/app/routes/actions\\.set-language\\.ts$|^apps/web/app/components/language-select/|^apps/web/\\.claude/rules/i18n\\.md$|^apps/web/\\.claude/agents/code-audit-frontend/react-i18next\\.md$|^apps/web/\\.claude/skills/react-code/references/translation-patterns\\.md$|^apps/web/\\.storybook/i18next\\.ts$|^apps/web/\\.playwright/e2e/language-switch-a11y\\.spec\\.ts$|^wiki/modules/i18n\\.md$|^wiki/flows/Language Flow\\.md$|^wiki/dependencies/i18next\\.md$|^wiki/dependencies/remix-i18next\\.md$")
      | not))
' .gaia/manifest.json > .gaia/manifest.json.tmp \
  && GAIA_MANIFEST_WRITE=remove-i18n mv .gaia/manifest.json.tmp .gaia/manifest.json
```

Discovery sweep, confirm no leftover entries:

```bash
grep -nE "i18n|languages/|LanguageSelect|set-language|language-switch-a11y|check-i18n|react-i18next|translation-patterns|Language Flow" .gaia/manifest.json
```

The only expected match is this runbook's own entry, `apps/web/.claude/instructions/remove-i18n.md`, it matches the sweep's broad `i18n` substring but is not an i18n content file and is not pruned here (the runbook self-deletes at the end of this process). Every i18n content key from the pattern list above is gone; that entry alone surviving is a pass.

---

## Section H, wiki

Edit each (skip any file that does not exist in this project):

- `wiki/index.md`, drop the lines `[[i18n]]`, `[[remix-i18next]]`, `[[i18next]]`.
- `wiki/overview.md`, drop the i18n bullet from "What's in the box". Drop `languages/` and `middleware/i18next.ts` mentions from the folder map. Drop any "i18n examples" row from feature tables.
- `wiki/modules/Folder Structure.md`, drop `languages/` and `middleware/i18next.ts` mentions.
- `wiki/modules/Middleware.md`, drop the `i18nextMiddleware` entry/section.
- `wiki/decisions/Quality Gate.md`, replace any "missing i18n keys" example with a generic "missing strings".
- `wiki/concepts/Component Testing.md`, drop "Render with i18n provider configured" if present.
- `wiki/dependencies/Storybook.md`, drop `storybook-react-i18next` from the addons list.
- `wiki/dependencies/React Router.md`, drop `[[remix-i18next]]` from related-deps lists.

Discovery sweep:

```bash
grep -rln "i18n\|useTranslation\|languages/\|i18next" wiki .claude apps/web/.claude
```

Review every match. Edit or delete each, the only acceptable surviving matches are inside this very file (`remove-i18n.md`) and inside the `add-locale.md` template. Section J deletes both.

---

## Section I, Verify

```bash
pnpm typecheck && pnpm lint && pnpm knip && pnpm test --run && pnpm build
```

If any step fails, **stop** and report the failing command + output verbatim. Do **not** proceed to Section J.

---

## Section J, Self-delete

On full verification success:

```bash
rm -f apps/web/.claude/instructions/add-locale.md apps/web/.claude/instructions/remove-i18n.md
```

Print: `remove-i18n, done`.
