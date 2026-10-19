# Hook Patterns, Extended Examples

Contents: When Effects ARE Correct; Strict Mode & Cleanup; Memoization; useEffectEvent, Non-Reactive Effect Logic; Ref Callback Cleanup.

## When Effects ARE Correct

Effects are appropriate for synchronizing with external systems.

### Data fetching: abort in the cleanup

Pass an `AbortController` signal and abort it in the cleanup. Aborting cancels the request and rejects the pending promise, so a stale response never reaches the setter. `@eslint-react/web-api-no-leaked-fetch` reports a `fetch` with no abort.

```tsx
useEffect(() => {
  const controller = new AbortController();

  fetch(`/api/gyms/${gymId}/exercises`, {signal: controller.signal})
    .then(async (response) => setExercises(await response.json()))
    .catch((error: unknown) => {
      if (!controller.signal.aborted) throw error;
    });

  return () => controller.abort();
}, [gymId]);
```

### An async client with no way to cancel

Guard the setter with an `ignore` flag, so a response that lands after the cleanup is dropped.

```tsx
useEffect(() => {
  let ignore = false;

  async function loadExercises() {
    const exercises = await client.listExercises(gymId);
    if (!ignore) setExercises(exercises);
  }

  void loadExercises();
  return () => {
    ignore = true;
  };
}, [gymId]);
```

### External store subscription

Lint (`no-external-store-subscription`) steers a store with a subscribe/getSnapshot pair to `useSyncExternalStore`. Use an Effect for third-party widgets or browser APIs that don't expose that pattern.

---

## Strict Mode & Cleanup

Strict Mode runs every Effect twice in development, so cleanup must fully undo the setup. Lint (`@eslint-react/web-api-no-leaked-*`) reports a listener, timer, interval, observer, or fetch with no cleanup. It does not see subscriptions or third-party widgets: tear those down by hand.

---

## Memoization

When to write a manual `useMemo`, `useCallback`, or `memo` is owned by `frontend/.claude/skills/react-code/SKILL.md` `## Memoization: compiler-first`. The default is none.

A hand-written memo's deps array is a stale-closure risk: a missing or stale dep makes the memoized value or function silently read an old snapshot, and an empty deps array breaks the moment the body needs current state or props. That is one more reason not to write one.

### Functions an Effect calls

```tsx
// BAD, a function defined outside the Effect becomes a dependency to manage
const fetchData = async () => {
  const result = await api.get(endpoint);
  setData(result);
};

useEffect(() => {
  fetchData();
}, [fetchData]);

// GOOD, define it inside the Effect; the only dependency is endpoint
useEffect(() => {
  let ignore = false;

  async function fetchData() {
    const result = await api.get(endpoint);
    if (!ignore) setData(result);
  }

  void fetchData();
  return () => {
    ignore = true;
  };
}, [endpoint]);
```

When the Effect must call a function that reads values it should not re-run for, use `useEffectEvent` (next section).

---

## useEffectEvent, Non-Reactive Effect Logic

`useEffectEvent` (stable in React 19.2) extracts a non-reactive read out of an Effect, so the Effect uses a current value without listing it as a dependency. It is the sanctioned replacement for "I had to omit X from the deps array" and for the latest-ref workaround (a callback ref updated during render behind an `eslint-disable react-hooks/refs`).

```tsx
// onVisit reads numItems, but the Effect should re-run only when url changes
const onVisit = useEffectEvent((visitedUrl: string) => {
  log(visitedUrl, numItems); // numItems is non-reactive here
});

useEffect(() => {
  onVisit(url);
}, [url]); // numItems intentionally absent, and lint won't demand it
```

Use it only for genuinely non-reactive values; a value the Effect should react to stays in the deps array.

---

## Ref Callback Cleanup

A ref callback may return a cleanup function, run when the element leaves the DOM. When it returns a cleanup, React no longer calls the callback again with `null`.

```tsx
<div
  ref={(node) => {
    const observer = new ResizeObserver(() => {/* … */});
    observer.observe(node);
    return () => observer.disconnect(); // runs on unmount
  }}
/>;
```

**Strict-TS pitfall:** because a returned value is now read as a cleanup function, an arrow ref-callback with an implicit return of a non-`undefined` value flags. Use a block body so the callback returns `undefined`.

```tsx
// BAD, implicit return of the assignment is read as a cleanup
<input ref={(node) => (ref.current = node)} />;
// GOOD, block body returns undefined
<input ref={(node) => { ref.current = node; }} />;
```
