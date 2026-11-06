import AxeBuilder from '@axe-core/playwright';
import {test as base, expect} from '@playwright/test';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {AXE_WCAG_TAGS} from '../test/axe-tags';
import {
  SERVER_READY_TIMEOUT_MILLISECONDS,
  START_LOCK_TIMEOUT_MILLISECONDS,
  startWorkerServer,
} from './worker-server';

/**
 * One Given builder: takes the input a spec names and returns the record it
 * made. A project's builders live in an adopter-owned file that extends the
 * `test` exported here, because this file is owned by the harness and is
 * overwritten on update. Each builder seeds the MSW store of the worker's own
 * server through `seedRecords` (`./msw-seed.ts`), which checks every record
 * against its collection's server schema, so a spec meets its Given without
 * driving a form. Give each record a unique identity (`crypto.randomUUID()`,
 * a unique email): a worker's store lives as long as its server, across specs.
 *
 *   // .playwright/project-fixtures.ts (adopter-owned)
 *   import {test as base} from './fixtures';
 *   import type {GivenBuilder} from './fixtures';
 *   import {seedRecords} from './msw-seed';
 *
 *   type Builders = {givenThing: GivenBuilder<{name: string}, ServerThing>};
 *
 *   export const test = base.extend<Builders>({
 *     baseURL: async ({workerServer}, provide) =>
 *       provide(workerServer.baseURL),
 *     givenThing: async ({workerServer}, provide) =>
 *       provide(async ({name}) => {
 *         const [thing] = await seedRecords<ServerThing>(
 *           workerServer.baseURL,
 *           'things',
 *           [{id: crypto.randomUUID(), name}]
 *         );
 *         return thing;
 *       }),
 *   });
 *
 * The builders are the seam between the mocks and a real backend: specs reach
 * setup only through them, never through the seed surface. A project that
 * runs the same specs as its own end-to-end suite swaps in builders that seed
 * its real backend and runs with `MSW_ENABLED=false`; GAIA ships none.
 *
 * A form's own submission is a real-server post whose body `serializeForm`
 * (`./html.ts`) builds from the served form.
 */
export type GivenBuilder<Input, Created> = (input: Input) => Promise<Created>;

type AxeFixtures = {
  makeAxeBuilder: () => AxeBuilder;
};

type WorkerServerFixtures = {
  workerServer: {baseURL: string};
};

const packageDirectory = fileURLToPath(new URL('..', import.meta.url));

/**
 * Extended Playwright test with an axe-core builder fixture (default tag set:
 * WCAG 2.0/2.1 A and AA) and a worker-scoped server fixture that gives each
 * worker its own MSW store.
 *
 * Worker isolation. Every worker seeds and reads the MSW store of its own
 * server, so a seeded record proves something only against the server that
 * holds it. `workerServer` starts this tree's `pnpm dev` on a free port with
 * MSW and its seed surface on, and stops only what it started;
 * `./worker-server.ts` owns the start. It is keyed on
 * `workerInfo.parallelIndex`, which stays stable when a worker restarts after
 * a failure, so a restarted worker appends to the same server log under
 * `.playwright/output/`. It is lazy: a fixture nothing requests never runs,
 * so the stock suite starts no extra server and `pnpm pw` is unchanged.
 *
 * A project activates it by overriding `baseURL` from `workerServer` in its
 * own file extending this `test` (see `GivenBuilder` above for the shape).
 *
 * A serial project is not an accepted way to share one store: it runs the
 * suite on one core.
 */
export const test = base.extend<AxeFixtures, WorkerServerFixtures>({
  makeAxeBuilder: async ({page}, provide) => {
    const makeWcagAxeBuilder = () =>
      new AxeBuilder({page}).withTags(AXE_WCAG_TAGS);

    await provide(makeWcagAxeBuilder);
  },

  workerServer: [
    async ({}, provide, workerInfo) => {
      const {baseURL, stop} = await startWorkerServer({
        outputDirectory: path.join(packageDirectory, '.playwright', 'output'),
        packageDirectory,
        parallelIndex: workerInfo.parallelIndex,
      });

      try {
        await provide({baseURL});
      } finally {
        stop();
      }
    },
    {
      scope: 'worker',
      // The margin lets a slow start report its own error and stop its server
      // before this timeout fires.
      timeout:
        START_LOCK_TIMEOUT_MILLISECONDS +
        SERVER_READY_TIMEOUT_MILLISECONDS +
        10_000,
    },
  ],
});

export {expect};
