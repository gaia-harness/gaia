# TanStack Query Patterns

Contents: Query Keys; Derived State; Dependent Queries; Pagination and Filters; Errors; Optimistic Mutations.

These apply only when Query is installed. Which data reads go through Query at all is decided by the Data Loading section of `SKILL.md`; nothing here relaxes it. Upstream TanStack Query guidance that reads data with `ensureQueryData`, `fetchQuery`, or `prefetchQuery` in a loader, or prefetches on the server into a `HydrationBoundary`, does not apply here: see `wiki/concepts/Data Loading.md`.

## Query Keys

Every variable the `queryFn` reads (id, filters, page, sort) goes in the `queryKey`. Two reads that differ by a variable missing from the key share one cache entry, so the second shows the first one's data. The scaffolded `list()` factory takes no arguments; when a list read gains a parameter, extend the factory instead of closing over the value:

```ts
export const itemKeys = {
  all: ITEMS_ROOT_KEY,
  detail: (id: string) => [...ITEMS_ROOT_KEY, 'detail', id] as const,
  list: (filters: ItemFilters) =>
    [...ITEMS_ROOT_KEY, 'list', filters] as const,
};
```

Keys stay under the service's `all` root, so `invalidateQueries({queryKey: itemKeys.all})` still reaches every variant.

## Derived State

- Never copy query data into `useState` or sync it with a `useEffect`. The copy goes stale on the next refetch and costs an extra render. Derive during render from the data plus the smallest client state: store `selectedId`, then `data.find(...)`.
- An edit form over query data keeps only the user's draft and overlays it: `value = draft.name ?? data.name`.
- Use `select` to subscribe to a slice or a derived value. Pass a module-level function, or a `useCallback` when it closes over props, so it does not rerun on every render. `select` sees only successful data: validate and throw in the request function (the Zod schema already does), never in `select`.

## Dependent Queries

A query that waits on another value takes `enabled: Boolean(value)`, or `queryFn: skipToken` when the value's type needs narrowing, and keeps that value in its key. Never call it with an `undefined` id.

`useSuspenseQuery` cannot be disabled: never pass it `enabled` or `skipToken`. Resolve the dependency in the `clientLoader`, or split the dependent read into a child component that renders once the value exists.

## Pagination and Filters

- A paged or filtered `useQuery` list takes `placeholderData: keepPreviousData` (imported from `@tanstack/react-query`) so changing the key keeps the previous page on screen instead of flashing a skeleton; `isPlaceholderData` dims it. The v4 `keepPreviousData: true` option no longer exists.
- `placeholderData` lives only in that observer and is never cached. `initialData` is written to the cache as real, fresh data: use it only for data that is real.
- `useInfiniteQuery` requires `initialPageParam` and `getNextPageParam`.

## Errors

- `useQuery` has no `onError`, `onSuccess`, or `onSettled` in v5. A global side effect, such as a toast, goes in the `QueryCache`'s `onError` where the client is built, so it fires once per query, not once per mounted observer.
- A failed background refetch keeps the data already on screen. Check `data` before `isError`, so stale data is not replaced by a full error state.
- A `useMutation` handles expected failures (validation, 4xx) next to the control that triggered it. Only unexpected failures reach the route `ErrorBoundary`: `throwOnError: (error) => error instanceof HTTPError && error.response.status >= 500`, with `HTTPError` from `ky`.

## Optimistic Mutations

`useMutation` is for in-place widget mutations that need optimistic UI; a mutation that ends in a navigation is a route action (`SKILL.md`, Data Loading). The recipe:

1. `onMutate` awaits `cancelQueries` on the affected key, so an in-flight refetch cannot overwrite the optimistic value.
2. It snapshots with `getQueryData`, writes the optimistic value with `setQueryData`, and returns the snapshot.
3. `onError` restores the snapshot.
4. `onSettled` returns the `invalidateQueries` promise, so the mutation stays pending until the refetch lands.

The `setQueryData` updater builds new objects with `map` and spread; it never mutates `old`.

```tsx
const queryClient = useQueryClient();

const {mutate} = useMutation({
  mutationFn: updateItem,
  onError: (_error, _variables, previous) => {
    queryClient.setQueryData(itemKeys.list(filters), previous);
  },
  onMutate: async (updated) => {
    await queryClient.cancelQueries({queryKey: itemKeys.list(filters)});
    const previous = queryClient.getQueryData(itemKeys.list(filters));
    queryClient.setQueryData(itemKeys.list(filters), (old) =>
      old?.map((item) => (item.id === updated.id ? {...item, ...updated} : item))
    );
    return previous;
  },
  onSettled: async () =>
    queryClient.invalidateQueries({queryKey: itemKeys.all}),
});
```

### Several mutations in flight

When the user can fire several optimistic mutations before the first settles (toggling rows in a list), the first to settle would refetch and revert the others. Give them a shared `mutationKey`, and invalidate in `onSettled` only when `queryClient.isMutating({mutationKey}) === 1`. To render pending rows straight from the mutations, read `useMutationState` and key each row by `mutation.state.submittedAt`, not by its variables, which collide on duplicate submits.
