# React Testing Reference (Storybook stories + Vitest projects + MSW)

Contents: Testing Layers; Component Tests via Stories; Hook Tests via `renderHook`; Service Tests via MSW; Route Tests; When to Mock; Testing Forms with Conform; Bad Tests; Worth Keeping: the Discriminator, Composition, and Platform Rules; Render-only stories and a11y; Red Flags.

## Testing Layers

Six layers share one mocking foundation (`msw` + `@msw/data`). Write tests at the layer the trophy rule in `wiki/decisions/Test Layering.md` picks, mostly route tests: a button's disabled state is a story `.test()`, not a browser test; a route's redirect is a route test; a loader's parsing gets a unit test only when it meets both unit-test conditions. The principle and its rationale are in `wiki/decisions/Test Layering.md`.

The story-versus-route boundary: rendered output on one component is a story. A status, a redirect, returned data, a validation error, an authorization outcome or a side effect is a route test.

| Layer             | Tool                                  | Vitest project | File location                           | What to assert                                      |
| ----------------- | ------------------------------------- | -------------- | --------------------------------------- | --------------------------------------------------- |
| Component / page  | Storybook story with `.test()` behaviors | `storybook`    | `app/components/<name>/tests/*.stories.tsx` | rendered DOM, user interactions, props behavior, accessibility |
| Hook              | `renderHook` from `vitest-browser-react` | `browser`   | `app/hooks/tests/`                      | hook return values, state transitions, callbacks    |
| Pure / service    | MSW handlers + Zod                    | `node`         | `app/services/<name>/tests/`, `app/utils/tests/` | parsed response shape, request payload, error cases |
| Route             | `loader` / `action` called with a `Request` | `node`      | `app/route-tests/<feature>/tests/*.test.ts` | status, redirect, returned data, validation errors, authorization outcome, side effect |
| Real server       | Playwright request fixture + dev-server MSW | Playwright  | `.playwright/e2e/<feature>/<flow>.spec.ts` or `.playwright/flows/<slug>.spec.ts` | what the live server serves, with no page: middleware, refusal status, forged requests, rendered HTML, native form posts with the body from `serializeForm`; see `wiki/decisions/Test Layering.md` |
| Browser           | Playwright page + dev-server MSW         | Playwright     | `.playwright/e2e/<feature>/<flow>.spec.ts` or `.playwright/flows/<slug>.spec.ts` | a capability from the closed list under `## When a test needs a real browser` in `wiki/decisions/Test Layering.md`, one journey per user flow; a critical web flow's spec under `.playwright/flows/` is allowed whatever a cheaper layer could prove |

One Vitest config (`vitest.config.ts`) holds the projects. `node` runs `*.test.ts` outside any `hooks/` folder; `browser` runs `*.test.tsx` and `hooks/**/*.test.ts` in headless Chromium; `storybook` runs every `*.stories.tsx` through `@storybook/addon-vitest`; `storybook-dark` runs the same stories in the dark theme with any-impact axe plus console, content and dark-class checks. There is no DOM emulation: component and hook code runs in a real browser, so install Chromium once with `pnpm install:browsers`. Run a subset with `pnpm test --run --project storybook <story-file>`.

## Component Tests via Stories

The story is the test. A story is a visual state, a behavior is a `.test()` attached to it, and a `play` only drives the UI into the state the snapshot must show; the doctrine is owned by `wiki/decisions/Stories as Tests.md`. Each story renders the component in a real browser through the same decorators Storybook shows (i18n, router, state via `test/stubs`). A story with no `.test()` is a render check that still runs and is axe-checked. Never write a separate `.test.tsx` that renders the component fresh: it bypasses the story's stubs and duplicates what the story already covers.

```tsx
// app/components/price-tag/tests/index.stories.tsx
import {expect} from 'storybook/test';
import preview from '#.storybook/preview';
import PriceTag from '..';

const meta = preview.meta({
  component: PriceTag,
  title: 'Components/PriceTag',
});

export const Default = meta.story({args: {amount: 4999, currency: 'USD'}});

export const Discounted = Default.extend({args: {discountPercent: 20}});

Default.test('renders the formatted price', async ({canvas}) => {
  await expect(canvas.getByText('$49.99')).toBeVisible();
});

Discounted.test('strikes through the original price', async ({canvas}) => {
  await expect(canvas.getByText('$39.99')).toBeVisible();
  await expect(canvas.getByText('$49.99')).toHaveClass('line-through');
});
```

Import `expect`, `fn`, `waitFor` and (when a native event has no `userEvent` equivalent) `fireEvent` from `storybook/test`, which re-exports the jest-dom matchers and user-event; a `.test()` and a `play` receive `canvas`, `canvasElement`, `args` and `userEvent` in their context. Use ARIA roles and accessible names as selectors, `getByRole('button', {name: 'Save'})`, `getByText('$49.99')`, not class selectors or test ids, and `await` every `userEvent` call and every `expect`.

One story per visual state and a `.test()` for each user-observable behavior (a parameterized table is one test), named for the behavior. The story export name is the story's display name (`Discounted` is "Discounted"); a string `name` overrides it. A story that carries any `.test()` runs its own render and play as `base story`, and the play runs again before every attached test, so put a step in `play` only when it builds the state every test and the snapshot need. A `play` on the meta is inherited by every story in the file, so put a shared play on the meta only when every story should run it. Write every story as a direct `meta.story({...})` export: the indexer cannot attach `.test()` to an export built by a factory function.

### Driving input

- Pointer: `await userEvent.click(...)` (from the test context), `await userEvent.selectOptions(select, 'ja')`.
- Keyboard: `await userEvent.keyboard('{Enter}')`, `await userEvent.tab()`; focus an element first with `element.focus()` when the path needs it. A native closed `<select>` arrow move is platform-dependent in Chromium, so drive it as `fireEvent.keyDown(select, {key: 'ArrowDown'})` followed by the `fireEvent.change` it causes.
- Settling: assert asynchronous results with `await waitFor(async () => { await expect(...)... })` or a `findBy*` query; assert that something did NOT happen only after a short settle delay long enough for a stray call to arrive.

### Overriding a prop (callback spies)

A spy reaches the component through story `args`. Declare it in the meta (`args: {onChange: fn()}`), spread `{...args}` onto the component **last** in the story's render, after any hardcoded default, and read the spy in the test through `args`. `args` only reaches the real component through that spread, so a story that hardcodes the callback, or spreads `{...args}` before it, silently drops the spy and a `not.toHaveBeenCalled()` assertion passes vacuously.

```tsx
// app/components/toggle/tests/index.stories.tsx
// GOOD - args carries the spy and is spread LAST, so the test's assertion is real
const meta = preview.meta({
  args: {onChange: fn()},
  component: Toggle,
  render: (args) => <Toggle label="Notifications" {...args} />,
});

export const Default = meta.story({});

Default.test('emits onChange when toggled', async ({args, canvas, userEvent}) => {
  await userEvent.click(canvas.getByRole('switch', {name: 'Notifications'}));
  await expect(args.onChange).toHaveBeenCalledWith(true);
});
```

```tsx
// BAD: hardcodes onChange after the spread, so the spy in args is dropped
render: (args) => <Toggle label="Notifications" {...args} onChange={() => {}} />,
// equally broken: a render that never accepts (args)
```

```tsx
// BAD: the spy is never wired, so this assertion passes vacuously
export const Disabled = meta.story({
  render: () => <Toggle disabled={true} label="Notifications" onChange={() => {}} />,
});

Disabled.test('does not emit while disabled', async ({args, canvas, userEvent}) => {
  await userEvent.click(canvas.getByRole('switch', {name: 'Notifications'}));
  await expect(args.onChange).not.toHaveBeenCalled(); // green even if the disabled guard is broken
});
```

### The router stub

`stubs.reactRouter()` from `test/stubs` wraps the story in a memory router. For a `.test()` that submits a form or navigates:

- `actions`: `Record<path, ActionFunction>`, a per-path action that overrides the no-op entry for that path. The action receives the real `request`, so a test asserts the submitted `FormData` through a `fn()` spy called from it.
- `destinations`: paths that render `Navigated to <path>` in a `main`, so the test asserts arrival with `findByText('Navigated to /done')`.
- Function form: `stubs.reactRouter(({args}) => ({actions: {...}}))` reads the story context, so one decorator serves every story and a story varies the router through its own `args` (a delay, a spy).

A story file carries exactly one `stubs.reactRouter` decorator, at meta level: routers do not nest. `actions` keys must differ from `path`, because the main route at `path` matches first and an action keyed to it never fires; a form posting to its own route is observed through the `action` option.

Configure a story through the component's props rather than shared constants. `LanguageSelect` takes an optional `languages` prop, so its stories pass `['en', 'ja']` and never touch the app-wide `LANGUAGES`.

## Hook Tests via `renderHook`

Hook tests run in the `browser` project in real Chromium. `renderHook` comes from `vitest-browser-react` and is async: `await` it, and `await` the `rerender` and `act` it returns.

```tsx
// app/hooks/tests/use-toggle.test.ts
import {describe, expect, test} from 'vitest';
import {renderHook} from 'vitest-browser-react';
import {useToggle} from '../use-toggle';

describe('useToggle', () => {
  test('starts with initial value', async () => {
    const {result} = await renderHook(() => useToggle(true));
    expect(result.current[0]).toBe(true);
  });
  test('toggles value', async () => {
    const {act, result} = await renderHook(() => useToggle(false));
    await act(() => result.current[1]());
    expect(result.current[0]).toBe(true);
  });
});
```

Assert on `result.current`, the observable hook surface. A `*.test.tsx` file also runs in the `browser` project; use `vitest-browser-react`'s `render` and `expect.element` there for a component that has no story.

## Service Tests via MSW

MSW handlers run inside the `node` Vitest project against the MSW node server, so a service test exercises the real `api()` wrapper, real schema validation, and real URL resolution. No `vi.mock('fetch')`. A page's rendered states are page stories with MSW handlers installed in the meta's `beforeEach` (`beforeEach: ({msw}) => { msw.use(...) }`), never through a story parameter; a route module's status, redirect, data or side effect is a route test (see Route Tests).

```tsx
// app/services/<layer>/things/tests/requests.test.ts
import {afterEach, describe, expect, test} from 'vitest';
import database, {resetTestData} from 'test/mocks/database';
import {attempt} from '~/services/api/helpers';
import {getThings} from '../requests';

describe('getThings', () => {
  afterEach(() => resetTestData());

  test('returns Zod-parsed Things collection', async () => {
    const things = await getThings();
    expect(things).toHaveLength(3);
    expect(things[0]).toMatchObject({
      id: expect.any(String),
      name: expect.any(String),
    });
  });

  test('reports a malformed response as a 500', async () => {
    await database.things.create({id: 'x', name: null as unknown as string});
    const result = await attempt(() => getThings());
    expect(result).toEqual([
      {status: 500, statusText: expect.any(String)},
      undefined,
    ]);
  });
});
```

The tracer bullet for services: the happy-path request returns a Zod-parsed result.

## Route Tests

A route test calls a route module's `loader` or `action` with a `Request` in the `node` project. HTTP boundaries are mocked through MSW; the app's own store is real, and each Vitest worker holds its own store. A case table lives in `test.each`. The principle and the limits of each layer are in `wiki/decisions/Test Layering.md`.

Pass full route args (`context`, `params`, `pattern`, `request`, `url`) and run any context-providing middleware by hand, since stock loaders read what middleware populated. `apps/web/test/root-toast.server.test.ts` is the shape:

```ts
import {RouterContextProvider} from 'react-router';
import {expect, test} from 'vitest';
import {i18nextMiddleware} from '~/middleware/i18next';
import {loader} from '~/root';

test('returns the loader data for an anonymous request', async () => {
  const url = new URL('http://localhost/');
  const request = new Request(url);
  const context = new RouterContextProvider();
  const args = {context, params: {}, pattern: '/', request, url};

  let result: Awaited<ReturnType<typeof loader>> | undefined;

  await i18nextMiddleware(args, async () => {
    result = await loader(args);

    return new Response();
  });

  expect(result?.data.toast).toBeUndefined();
});
```

What a route test cannot prove:

- A direct call skips middleware, so a middleware guard is proven by a real-server check.
- A parent loader guards no action. A write action guards itself, and a direct anonymous call to it is the proof.
- A parent-loader guard on a read is proven by a real-server `.data` request naming only the child route.
- An authorization outcome owned by an upstream API cannot be proven by a route test, since an MSW handler answers as the test wrote it.

## When to Mock

Mock at **system boundaries** only:

| Boundary                | Mock via                               | Example                                       |
| ----------------------- | -------------------------------------- | --------------------------------------------- |
| HTTP / external APIs    | MSW handlers in `test/mocks/`          | REST calls made by `app/services/`            |
| Database read/write     | `@msw/data` collections via `database` | `await database.things.create(...)` in a test |
| Time                    | `vi.useFakeTimers()`                   | Debounced handlers, TTL expiry                |
| Randomness              | `vi.spyOn` at boundary                 | IDs, crypto                                   |
| Navigation (story scope) | `stubs.reactRouter({destinations})`   | Buttons that push to `/done`                  |

**Run for real:**

- Your own services, hooks, components and utilities: a component using `useThings()` reads the real hook from real MSW.
- `react-router` and `react-i18next`, through `stubs.reactRouter()` / `stubs.state()` from `test/stubs` (i18n for stories is wired in `.storybook/i18next.ts`).
- Zod schemas: a parse failure is a real bug the test should surface.

**Mutating data in a test**: write to `database` directly; reset in `afterEach` via `resetTestData()` from `test/mocks/database`. The read-then-verify shape tests the interface end-to-end and survives schema renames as long as the public service contract holds.

The MSW server runs in the `node` Vitest project and Playwright browser and real-server tests run against the dev server, where MSW mocks both browser and SSR requests (`wiki/dependencies/MSW.md`); stories install handlers in `beforeEach` through the `msw` context or read seed data from the same `database` collections directly.

## Testing Forms with Conform

For components using `@conform-to/react`, create a story that wraps the component with `useForm`, then drive it with a `.test()`:

```tsx
export const Default = meta.story({
  render: () => {
    const [form, fields] = useForm({
      constraint: getZodConstraint(schema),
      onValidate: ({formData}) => parseWithZod(formData, {schema}),
    });

    return (
      <Form {...getFormProps(form)}>
        <MyFormComponent fields={fields} />
      </Form>
    );
  },
});
```

### Custom form components: use `useInputControl`

When using custom form components (like a `TimePicker` or a date picker) that manage their own internal state, you **must** use `useInputControl` to properly integrate them with Conform's validation state:

```tsx
// BAD - Local state conflicts with Conform's validation
const [value, setValue] = useState(savedData?.field ?? DEFAULT);
const handleChangeValue = (newValue) => {
  setValue(newValue);
};

<CustomComponent onChange={handleChangeValue} value={value} />;

// GOOD - useInputControl keeps component synced with Conform
const fieldControl = useInputControl(fields.fieldName);

<CustomComponent
  onBlur={fieldControl.blur}
  onChange={fieldControl.change}
  value={fieldControl.value ?? DEFAULT}
/>;
```

**Why this matters**: When validation fails, Conform takes control of the field value. If you use local `useState`, the component becomes disconnected from Conform's state and stops responding to changes after validation errors occur.

## Bad Tests

```tsx
// BAD: asserts on translation internals, not user output
export const GreetsTheUser = meta.story({
  render: () => <Greeting name="Ada" />, // with react-i18next mocked to a tSpy
});

GreetsTheUser.test('greets the user', async () => {
  await expect(tSpy).toHaveBeenCalledWith('greeting.hello', {name: 'Ada'});
});
```

Why bad: renaming the key (`greeting.hello` → `pages.home.greeting`) breaks the test even though the user still sees "Hello, Ada". Assert `getByText('Hello, Ada')`.

```tsx
// BAD: mocks react-router, tests the mock
vi.mock('react-router', () => ({useNavigate: () => mockNavigate}));
export const Default = meta.story({});

Default.test('navigates to done on submit', async ({canvas, userEvent}) => {
  await userEvent.click(canvas.getByRole('button'));
  await expect(mockNavigate).toHaveBeenCalledWith('/done');
});
```

Why bad: tests the mock, not the component. Use `stubs.reactRouter({destinations: ['/done']})` and assert on the resulting page (`findByText('Navigated to /done')`).

```tsx
// BAD: reads MSW internals
test('saveThing called POST', async () => {
  const handler = server
    .listHandlers()
    .find((h) => h.info.path.endsWith('/things'));
  expect(handler).toBeDefined();
});
```

Why bad: handler existence proves nothing. Assert on the effect, database state after the call, or the returned value.

## Worth Keeping: the Discriminator, Composition, and Platform Rules

A test that passes can still be worthless. The honesty rules ("Bad Tests" above) ask whether a test _can_ fail for a real reason; these rules ask whether the test is worth having at all. Tests that re-prove a dependency, re-prove a child component, or pin the byte output of a platform formatter add maintenance cost and break on unrelated upgrades while catching none of your bugs.

### The discriminator

Before keeping any test, ask:

> If this test failed, would the bug be in MY code or in the dependency? If the dependency, delete the test.

`date-fns`, `Intl`, Zod, `react-router`, `react-i18next` all have their own suites. A test whose only failure mode is "the library changed" tests the library, not you.

### The composition rule

A `.test()` on a story for component `C` asserts the **emergent behavior of its children together**: the seam where data and events flow through `C`. It never re-proves what the children's own stories already cover.

```tsx
// app/components/checkout/tests/index.stories.tsx
// GOOD - the seam: PriceTag + QuantityStepper feeding the running total in Checkout
Default.test('total updates when quantity changes', async ({canvas, userEvent}) => {
  await userEvent.click(canvas.getByRole('button', {name: 'Increase quantity'}));
  await expect(canvas.getByRole('status', {name: 'Order total'})).toHaveTextContent('$99.98');
});

// BAD - re-proves PriceTag's own stories; nothing here is about Checkout
Default.test('price renders with two decimals', async ({canvas}) => {
  await expect(canvas.getByText('$49.99')).toBeVisible(); // PriceTag's job, covered in PriceTag's stories
});
```

The composition rule compares a story's tests with its own children's stories and stays on that surface. Comparing a test with one at another layer (a story against a route test, a route test against an end-to-end test) is the overlap pass, which reads every layer (`wiki/decisions/Test Layering.md`).

This is a judgment call, not a lint rule: applied bluntly it strips real integration regressions. An agent applies it **PROPOSE-only and NEVER auto-deletes a child-redundant test.** Any proposed delete must cite both the specific redundant sibling assertion AND the seam assertion that subsumes it, and the cited sibling assertion is machine-verified to contain a matching assertion before the proposal reaches a human. Security, escaping, and data-integrity seam tests (for example a Toast XSS-escaping test) carry a never-delete-without-a-verified-sibling carve-out: they stay even when a sibling looks redundant.

### The platform rule

When a helper delegates to a platform formatter (`Intl`, `date-fns`), test the logic you own, not the formatter's output bytes.

```tsx
// WORTHLESS - tests Intl, not you
// formatPrice = (n) => new Intl.NumberFormat('en-US',
//   {style: 'currency', currency: 'USD'}).format(n);
test('formats as USD', () => expect(formatPrice(49.99)).toBe('$49.99'));

// WORTHY - tests YOUR logic; Intl is just the boundary it delegates to
// formatPrice = (cents, currency) => {
//   if (cents == null) return '';
//   return new Intl.NumberFormat(LOCALE_BY_CURRENCY[currency],
//     {style: 'currency', currency}).format(cents / 100);
// };
test.each([
  {case: 'null amount', cents: null, currency: 'USD', match: /^$/},
  {case: 'cents to major units', cents: 4999, currency: 'USD', match: /^\$49\.99$/},
  // Tolerant matcher: Intl spacing varies by ICU version.
  {case: 'locale for the currency', cents: 4999, currency: 'EUR', match: /49,99.*€|€.*49,99/},
])('formatPrice applies its own logic: $case', ({cents, currency, match}) => {
  expect(formatPrice(cents, currency)).toMatch(match);
});
```

The null-amount guard and the cents-to-major conversion and the currency-to-locale selection are yours. The decimal separator, currency glyph, and spacing belong to `Intl`. Assert the first set; tolerate the second.

## Render-only stories and a11y

A story with no `.test()` renders the component and is axe-checked by addon-a11y (WCAG 2.0/2.1 A and AA, any impact fails; `region` is off); the check runs for the base story and again for each attached test. That is **complete evidence ONLY for a component with no interactive behavior** (a Spinner, a static badge). For a behavior-rich component a render-only story is the start of a test, not the whole of it: the behavior it owns still needs `.test()` coverage of the behavior a user sees (interactions, state transitions and error paths), not one test per interaction.

An axe pass says nothing about focus order, keyboard operation, or the accessible state of controls a user drives. For an interactive component, the tests assert a keyboard path (Tab, Enter, Escape, arrows as the widget requires) and a focus outcome (where focus lands, or that it returns to the trigger). Page stories also carry a `.test()` for the landmark structure (one `main`, one level-1 heading), which the story-level axe run does not check. Opting a story out of addon-a11y needs its story id and a reason recorded in `A11Y_OPT_OUT_REASONS` in `test/story-a11y-opt-out.test.tsx`.

## Red Flags

- `vi.fn()` spy on a function the component uses internally
- `toHaveBeenCalled` as the only assertion (you're testing call-through, not behavior)
- Importing from `../internals` or `.server.ts` files the public consumer wouldn't touch
- Test names like "`useX` returns an object with `a`, `b`, `c`", that's testing shape, not behavior
- A fixture file larger than the code it tests
