---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-28
tags: [concept, testing]
---

# Component Testing

## A behavior is a `.test()` on a story

A story is a visual state and a behavior is a `.test()` attached to it; a play only drives the UI into the state and asserts nothing ([[Stories as Tests]] owns the doctrine and the harness rules). Vitest runs each test in headless Chromium through `@storybook/addon-vitest`, so the story's decorators, stubs, mocked context and i18n are the test's setup and nothing re-derives them in a second file. There is no `.test.tsx` beside a component's stories and no standalone `render()`. Assertions use `expect` and `fn` from `storybook/test`, and the test receives `canvas`, `args` and `userEvent` from its context. One test covers one behavior, named for it. `frontend/.claude/rules/storybook.md` owns authoring.

```tsx
Default.test('shows the required error', async ({canvas}) => {
  await expect(await canvas.findByRole('alert')).toHaveTextContent('Required');
});
```

## Stubs, never framework mocks

> [!warning] Never manually mock framework deps
> Don't mock `react-router`, `react-i18next`, or other framework deps. Use the stubs in `frontend/test/stubs/` instead; they wire real providers with sensible defaults.

`frontend/test/stubs/` exposes `stubs.reactRouter()`, `stubs.state()`, etc. Apply as decorators in the component's story file under `tests/`; the same decorators serve Storybook, Chromatic and the Vitest run. Only mock **external services** or **utilities** the component imports directly.

## Spying on a callback

A test that asserts a callback ran needs the spy to reach the real component. Declare the spy as an arg (`fn()`) and pass it into the rendered component from the story's `render`, spreading `{...args}` **last**, after any hardcoded default. A story that hardcodes the callback, or spreads `{...args}` before it, silently drops the spy. The assertion still runs, it just proves nothing: `not.toHaveBeenCalled()` passes vacuously with the callback never wired, so the story stays green even if the behavior it guards is broken.

```tsx
// GOOD - accepts args and spreads {...args} LAST, so the fn() spy reaches onChange
const render = (args: ToggleProps) => (
  <Toggle label="Notifications" onChange={() => {}} {...args} />
);
```

```tsx
// BAD - hardcodes onChange after the spread (or never accepts args), so the spy is dropped
const render = (args: ToggleProps) => (
  <Toggle label="Notifications" {...args} onChange={() => {}} />
);
```

## Custom Conform inputs

Stateful custom form components MUST use `useInputControl` to stay in sync with Conform validation state. Local `useState` desyncs once validation fails. See [[Form Components]] § warning.

## Reference example

`frontend/app/components/form/tests/composed-form.tsx`: a Conform form composed from ui `Field` parts, with its stories, whose attached tests are the integration tests.

For the current file pattern (where stories and hook tests go), the scaffolders (`/new-component`, `/new-route`) handle it; read an existing component's folder rather than maintaining the layout here.

## Accessibility assertions

`@storybook/addon-a11y` axe-checks every story with no assertion written, so a render-only story is already an accessibility test. A page story adds a `.test()` asserting one level-1 heading and a `main` landmark, because addon-a11y scopes axe to the body. See [[Accessibility]].
