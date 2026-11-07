// Barrel for `@msw/data` collections.
//
// Each `/new-service` adds two things to this file:
//   1. A re-export of the domain's `Collection` (so stories and tests can
//      `import database from 'test/mocks/database'` and reach `database.things`).
//   2. A call to the domain's `reset*` in `resetTestData`.
//
// `resetTestData` is the baseline: Vitest's node project runs it after each
// case, a Playwright worker server runs it before serving its first request,
// and any other MSW dev server runs it when `app/entry.server.tsx` evaluates.
// Put baseline records in a `reset*` default seed, never in a
// top-level call here: that reset clears whatever else created them.
//
// Empty until the first `/new-service` is run.

export const resetTestData = async (): Promise<void> => {};

export default {} as Record<string, never>;
