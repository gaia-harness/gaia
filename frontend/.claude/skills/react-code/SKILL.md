---
name: react-code
description: Applies GAIA's patterns and conventions for writing and editing React components and hooks. Use this skill whenever writing or reviewing React components, hooks, or event handlers, or deciding on component extraction. Also trigger when deciding whether a manual memo or "use no memo" is justified under React Compiler, debugging stale closures or infinite re-renders, weighing a new dependency against a web-platform API or a hand-rolled primitive, choosing a React 19 idiom, or reaching for React's form Actions instead of React Router's form handling.
---

# React Code

Write and edit React components, pages, routes, hooks, and forms following project conventions.

Contents: Reach for the Platform First; Pre-Flight Gates; Memoization: compiler-first; Component Structure; Data Loading; Route-Page Architecture; References.

## Reach for the Platform First

Before installing a package or hand-rolling a primitive, walk this ladder and stop at the first hit:

1. **Existing project code**, a component, hook, or util already covers it (form inputs → Gate 2).
2. **Web platform**, a browser API or native element does the job (`Intl`, `URL`, `structuredClone()`, `<dialog>`, modern CSS).
3. **Already-installed dependency**, check `package.json` before adding a sibling that does the same job. For component/hook traps Claude often hand-rolls (client-only/useHydrated, sse, debounce-fetcher), see the remix-utils decision map at `wiki/dependencies/remix-utils.md` before reinventing.
4. **New dependency**, only when 1-3 genuinely fall short; the added weight has to earn its place.
5. **Custom code**, last resort, kept minimal.

Reaching for the platform replaces a needless dependency or bespoke widget; it never overrides accessibility, input validation, or an existing project component (a wrapper exists for a reason).

## Pre-Flight Gates

Run each gate when its pattern appears in your changes.

### Gate 1: Hook Check

**Before writing `useEffect`:** decide whether it should be an Effect at all. Lint (`react-you-might-not-need-an-effect`) reports the ones that should not: state derived from props or state, user-event logic, chained updates, notifying a parent, and resetting state on a prop change. An Effect is right when it synchronizes with an external system (browser API, third-party widget, network). Add cleanup (a fetch aborts its `AbortController`; a client that cannot cancel uses an `ignore` flag: `references/hook-patterns.md`).

**Before writing `useMemo`, `useCallback`, or `memo`:** don't; see `## Memoization: compiler-first`.

**`useState`:** for an absent initial value, prefer `undefined` over `null` (never-null convention): `useState<T>()` is already typed `T | undefined`.

### Gate 2: Form Element Check

**Before writing `<input>`, `<select>`, `<textarea>`, or `<input type="checkbox">`:**

| Native element                         | Use instead (`~/components/ui/...`)                                                  |
| -------------------------------------- | ------------------------------------------------------------------------------------ |
| `<input type="text">` (any text type) | `Input` (`input`)                                                                    |
| `<input type="checkbox">`              | `Checkbox` (`checkbox`); a group is one `Checkbox` per option in a `FieldSet`        |
| `<input type="radio">` / radio group   | `RadioGroup` and `RadioGroupItem` (`radio-group`) in a `FieldSet`                    |
| `<select>`                             | `NativeSelect` and `NativeSelectOption` (`native-select`)                            |
| `<textarea>`                           | `Textarea` (`textarea`)                                                              |
| `<label>`                              | `FieldLabel` (`field`), or `Label` (`label`) outside a `Field`                       |
| Field with label + error + description | `Field`, `FieldLabel`, `FieldDescription`, `FieldError` (`field`)                    |
| `<button>`                             | `Button` (`button`)                                                                  |

**Exceptions (native OK):** `<input type="hidden">`, `<input type="file">`, `<input type="range">`.

A raw ui control carries no label or error wiring. Compose it with Conform exactly as `references/conform-forms.md` shows (one pattern per control type, with the `Field` wiring). Render options from an array with `.map`.

**CRITICAL, `@conform-to/zod`:** Always import from `/v4` subpath. The default export targets Zod v3 and causes a runtime error that typecheck and build do NOT catch (lint flags the bare import).

```tsx
// BAD, runtime error
import {parseWithZod} from '@conform-to/zod';
// GOOD
import {parseWithZod} from '@conform-to/zod/v4';
```

See `references/conform-forms.md` for full Conform + Zod wiring. Beyond the import path, all Zod schemas use Zod 4 syntax, the typescript skill's `references/zod.md` is the canonical Zod 3 → Zod 4 migration map (`z.strictObject`, top-level string formats, etc.).

### Gate 3: Translation Check

**Before writing ANY user-visible string in JSX:**

Every string a user can see or hear, including `aria-label`, `alt`, `title` and placeholder attributes, must come from a `t()` call. Lint (`i18next/no-literal-string`) reports raw JSX text but not attributes, so `aria-label`, `alt`, `title`, and placeholders are yours to check. This applies to new components, new UI sections, and modifications that add visible text. The only exceptions are punctuation-only strings, single-character symbols, developer-facing content (console.log, comments, test assertions), and approximate skeleton-loader placeholder text standing in for a dynamic runtime value. Skeleton text that mirrors static `t()` content must still use `t()` (see the skeleton-loaders skill).

1. Add the translation key to the appropriate namespace file in `app/languages/en/` (and any other locale folders present, copying the English string verbatim as a placeholder)
2. Use `t('key')` in the component, never a string literal
3. **One `useTranslation()` per component**: never multiple calls for different namespaces
4. Use `{ns: 'other'}` as second arg to `t()` for cross-namespace access
5. Choose the most-used namespace for `useTranslation()` to minimize overrides
6. **Before adding a new key:** search `app/languages/en/` for existing equivalent strings
7. Dynamic keys: ensure interpolated values have literal union types, not `string`

See `references/translation-patterns.md` for edge cases (keyPrefix, Trans component, dedup).

### Gate 4: React 19 Idiom Check

Write React 19 idioms. The work here is to not regress to pre-19 habits, and to not pull in React's framework-level form APIs that React Router already owns.

**`forwardRef`:** lint (`@eslint-react/no-forward-ref`) reports it. In React 19 `ref` is an ordinary prop, so destructure it from props. The ref _type_ (`Ref<T>`, or `ComponentProps<'input'>` already carrying `ref`) is the typescript skill's domain.

**Before writing `&&` in JSX, make the left operand a real boolean.** `&&` returns its left operand when falsy. `false`/`null`/`undefined` render nothing, but a numeric **`0`** is a renderable value and leaks the literal "0" into the DOM. Lint catches both forms in real time: `no-restricted-syntax` reports `.length && <JSX/>`, and the type-aware `sonarjs/jsx-no-leaked-render` reports the general `count && <X/>` case. Coerce as you write: `count > 0`, `count !== 0`, or `!!count`.

```tsx
// BAD, renders "0" when the list is empty
{items.length && <List items={items} />}
// GOOD, force a real boolean
{items.length > 0 && <List items={items} />}
```

For render-or-nothing, a boolean-guarded `&&` is the idiom; it replaces the old `cond ? <X/> : null`. A ternary is only for a genuine either/or where both arms render, never `: null`.

**`useContext` and `<Context.Provider>`:** lint (`@eslint-react/no-use-context`, `@eslint-react/no-context-provider`) reports them. Read context with `use()` (it may be called conditionally or after an early return) and render the context object as the provider: `<NonceContext value={nonce}>`. Lint misses `<Context.Consumer>`, and the provider rule matches by name, so it can miss a `.Provider` on a context not named `…Context`; convert those by hand.

**Use React Router for forms, not React 19 form Actions.** Submit through React Router `<Form>` / `useFetcher` + route `action` exports, validate with Conform + Zod (Gate 2), and read pending/optimistic state from React Router. React 19's framework-level form hooks duplicate and fight that surface. Map each React 19 API to its router equivalent:

| React 19 API                           | Use instead                                                                                   |
| -------------------------------------- | --------------------------------------------------------------------------------------------- |
| `useActionState`, `<form action={fn}>` | route `action` + `useActionData`                                                              |
| `useFormStatus`                        | `useNavigation().state` / `fetcher.state`                                                     |
| `useOptimistic`                        | fetcher-based optimism (`useOptimisticThemeMode` in `use-theme.ts`)                           |
| `use(promise)` for route data          | the route's data-loading variant (`## Data Loading`); `use(promise)` only for non-route promises inside `<Suspense>` |

Metadata is the mirror case: render `<title>`/`<meta>` as JSX (React 19 hoisting), not a React Router route `meta`/`links` export. Keep it that way; adding a route `meta` export to a page that already renders `<title>` in JSX produces duplicate tags.

When you do reach for React Router's API, read it from the version-matched docs shipped at `frontend/node_modules/react-router/docs`, not the web.

For `useEffectEvent` (the sanctioned replacement for stale-deps / latest-ref hacks) and ref-callback cleanup functions, see `references/hook-patterns.md`.

## Memoization: compiler-first

React Compiler is on by default and memoizes components and hooks automatically. **Write plain code: inline callbacks, inline object props, and derived values need no `useMemo`, `useCallback`, or `memo` wrapper.**

A manual memo is allowed in exactly two cases, and each one carries a one-line comment naming its case:

1. **A value crosses into code the compiler does not compile**: a third-party hook or component that relies on referential identity, or a file opted out with `"use no memo"`.
2. **A component bails out of compilation and the memo is measured to matter.**

A `"use no memo"` directive always carries a comment stating why. Opting out is a last resort: the default fix is to make the code follow the Rules of React.

```tsx
// Case 1: third-party chart compares `options` by identity and is not compiled.
const options = useMemo(() => ({series, theme}), [series, theme]);

const LegacyForm = (props: LegacyFormProps) => {
  // reason: legacy class-based form library mutates props during render
  'use no memo';
  // ...
};
```

The directive takes effect only as the first statement of a function or module body.

## Component Structure

- **Inline props typing:** `type MyComponentProps = {...}; const MyComponent = ({...}: MyComponentProps) => ...`; a generic component is `const List = <T,>({items}: ListProps<T>) => ...`
- **One component per file**: keeps co-location clean and makes code-splitting predictable
- **Named React imports, values and types:** `import {useState} from 'react'`, `import type {ChangeEventHandler} from 'react'`; no `React.` namespace
- **Event handler types:** Prefer `ChangeEventHandler<HTMLInputElement>` over inline event typing
- **Event handler naming:** `handle{Action}{Element}`, the `{Element}` is required so the name says _what it does_, not just _when it fires_; e.g. `handleClickSave`, `handleChangeInput`, `handleCopyStack`. A bare event name (`handleClick`, `handleChange`, `handleSubmit`) breaks this convention (react-doctor's `no-generic-handler-names` is off by default, so review catches it).

### Component Extraction

Extract when a section meets **all** criteria:

1. Self-contained (own state/fetcher, or pure display with no shared state or tightly coupled form validation)
2. Clear boundary (visible UI section with small props interface)
3. ~60+ lines of JSX/logic

How: Create `parent-component/new-section/index.tsx`, move exclusive types/state/handlers/JSX, define minimal `Props` type.

## Data Loading

Pick the variant by who owns the data:

- **URL-owned data** (no cross-route reuse, no polling): a server `loader` + `useLoaderData` by default, for first-paint, public, or SEO-relevant content. A `clientLoader` + `HydrateFallback` + `useLoaderData` only for browser-only or post-interaction data where an empty first paint is acceptable: the server renders only the `HydrateFallback`, so content waits on HTML, JS, hydration, then the fetch.
- **Component-owned data**: `useQuery`, or `useSuspenseQuery(` only inside a `clientLoader` route, whose component never renders on the server. With Query off, run `./.gaia/cli/gaia init configure-data-layer --query true`; never a hand-rolled fetch cache or effect-based fetching.
- **Both** (URL-owned and cached): the `clientLoader` awaits `queryClient.query(options)` (via `getQueryClient()`) and returns nothing, the page reads `useSuspenseQuery(options)`, and the `clientAction` mutates then awaits `invalidateQueries` before redirecting.
- Server-rendered data comes from a server loader; Query is for client-owned data. Never `ensureQueryData`, `fetchQuery`, or `prefetchQuery` (lint enforces it).
- Any identity change (logout, login, account switch) calls `queryClient.clear()` or does a full document navigation, so one user's cache never reaches the next.
- `clientLoader` and Query variants suit unauthenticated or cookie-authenticated APIs; tokens and secrets never enter the root-loader `ENV`.

Worked example and rationale: `wiki/concepts/Data Loading.md`. Scaffolds: the `new-route` and `new-service` skills. Writing `useQuery`, `useMutation`, or a key factory: `references/query-patterns.md`.

## Route-Page Architecture

### Route files (`app/routes/`)

Thin shell only:

- `loader`, `clientLoader`, `action`, `clientAction`, and `HydrateFallback` exports, as the data-loading variant needs
- Zod schemas for the action
- One-line default export: `const MyRoute = () => <MyPage />;`

**No UI code, hooks, state, or sub-components in route files.**

### Page components (`app/pages/`)

```
app/pages/<route path>/page.tsx          # default export <Name>Page
app/pages/<route path>/tests/page.*.tsx  # the page's tests and stories
```

The folder is derived from the route file name; the full layout rule (derivation, colocation, hooks) lives in `frontend/.claude/rules/coding-guidelines-react.md`.

For loader data: use `useLoaderData<LoaderData>()` with `LoaderData` exported from a sibling `types.ts` in the page folder, and annotate the route module's loader return with that type. A page never imports from `app/routes/**` (type-only included; `import-x/no-restricted-paths` forbids it), so it never reads the `loader` type from the route file.

Page content goes in colocated `<kebab>/index.tsx` folders inside the page folder. Tests and stories go in the page folder's `tests/`.

A story file carries exactly one `stubs.reactRouter()` decorator, because a nested Router throws. When stories need different loader data, either put the decorator on each story and none on meta, or keep it on meta and pass it the function form (`stubs.reactRouter(({args}) => ({...}))`) so each story varies the options through its args or parameters.

## References

- `references/hook-patterns.md`, Read when writing any Effect, or when debugging stale closures, double-firing effects, or infinite re-renders.
- `references/conform-forms.md`, Read before writing or editing a form: the Conform + Zod wiring for each ui control.
- `references/query-patterns.md`, Read when Query is installed and you write a query key, `useQuery`, `select`, a dependent or paged query, a mutation's error handling, or an optimistic `useMutation`.
- `references/translation-patterns.md`, Read when a translation needs `keyPrefix`, a cross-namespace override, a dynamic key, the `Trans` component, or plurals.
