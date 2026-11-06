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
 * One Given builder: takes the input a spec names and returns the row it made.
 * A project's builders live in an adopter-owned file that extends the `test`
 * exported here, because this file is owned by the harness and is overwritten
 * on update. Each builder writes through the database the worker's own server
 * reads, so a spec meets its Given without driving a form:
 *
 *   // .playwright/project-fixtures.ts (adopter-owned)
 *   import {test as base} from './fixtures';
 *   import type {GivenBuilder} from './fixtures';
 *
 *   type Builders = {givenThing: GivenBuilder<{name: string}, ThingRow>};
 *
 *   export const test = base.extend<Builders>({
 *     baseURL: async ({workerServer}, provide) =>
 *       provide(workerServer.baseURL),
 *     givenThing: async ({workerServer}, provide) =>
 *       provide(async ({name}) => insertThing(workerServer.databaseFile, name)),
 *   });
 *
 * A form's own submission is a real-server post whose body `serializeForm`
 * (`./html.ts`) builds from the served form.
 */
export type GivenBuilder<Input, Row> = (input: Input) => Promise<Row>;

type AxeFixtures = {
  makeAxeBuilder: () => AxeBuilder;
};

type WorkerServerFixtures = {
  workerServer: {baseURL: string; databaseFile: string};
};

const packageDirectory = fileURLToPath(new URL('..', import.meta.url));

/**
 * Extended Playwright test with an axe-core builder fixture (default tag set:
 * WCAG 2.0/2.1 A and AA) and a worker-scoped server fixture for database
 * isolation.
 *
 * Worker isolation. Every worker reaches its own database through the server
 * it talks to, so a spec that seeds a database proves something only against
 * the server that reads it. `workerServer` starts this tree's `pnpm dev` on a
 * free port with a per-worker file database in its own temp folder on local
 * disk, passes that file to the process as `DATABASE_URL` (the project's
 * database module reads it), and stops only what it started;
 * `./worker-server.ts` owns the start. It is keyed on
 * `workerInfo.parallelIndex`, which stays stable when a worker restarts after
 * a failure, so a restarted worker appends to the same server log under
 * `.playwright/output/`. It is lazy: a fixture nothing requests never runs,
 * so the stock suite starts no extra server and `pnpm pw` is unchanged.
 *
 * A project activates it by overriding `baseURL` from `workerServer` in its
 * own file extending this `test` (see `GivenBuilder` above for the shape).
 *
 * Rules for a project that does:
 * - A serial project is not an accepted way to share one database. It runs
 *   the suite on one core. Give each worker its own database instead.
 * - Schema selection is the mapping for a database server: one schema per
 *   worker on a shared server. A shared database server's key includes the
 *   tree identity along with `parallelIndex`, as `.gaia/scripts/ports.sh` does
 *   for ports, so two trees never collide on one worker's schema. A file
 *   database in its own temp folder is already unique to the tree.
 * - State in the dev server's MSW handlers is out of reach of the Playwright
 *   process, so a stock project has no builder target: builders need a real
 *   database.
 */
export const test = base.extend<AxeFixtures, WorkerServerFixtures>({
  makeAxeBuilder: async ({page}, provide) => {
    const makeWcagAxeBuilder = () =>
      new AxeBuilder({page}).withTags(AXE_WCAG_TAGS);

    await provide(makeWcagAxeBuilder);
  },

  workerServer: [
    async ({}, provide, workerInfo) => {
      const {baseURL, databaseFile, stop} = await startWorkerServer({
        outputDirectory: path.join(packageDirectory, '.playwright', 'output'),
        packageDirectory,
        parallelIndex: workerInfo.parallelIndex,
      });

      try {
        await provide({baseURL, databaseFile});
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
