import AxeBuilder from '@axe-core/playwright';
import {test as base, expect} from '@playwright/test';
import {spawn} from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {DEV_PORT_OVERRIDE_ENV, isPortTaken} from '../dev-ports';
import {AXE_WCAG_TAGS} from '../test/axe-tags';

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
 * One spec per form stays on the UI path, so the form itself is still driven
 * through the browser.
 */
export type GivenBuilder<Input, Row> = (input: Input) => Promise<Row>;

type AxeFixtures = {
  makeAxeBuilder: () => AxeBuilder;
};

type WorkerServerFixtures = {
  workerServer: {baseURL: string; databaseFile: string};
};

const SERVER_READY_TIMEOUT_MILLISECONDS = 60_000;
const SERVER_POLL_INTERVAL_MILLISECONDS = 250;
const SERVER_STARTUP_MARGIN_MILLISECONDS = 10_000;

const packageDirectory = fileURLToPath(new URL('..', import.meta.url));

const askOperatingSystemForPort = async (): Promise<number> =>
  new Promise((resolve, reject) => {
    const probe = net.createServer();

    probe.once('error', reject);
    probe.listen({exclusive: true, host: '0.0.0.0', port: 0}, () => {
      const {port} = probe.address() as net.AddressInfo;

      probe.close(() => resolve(port));
    });
  });

// Asks the OS for a port, then confirms no listener holds it on any address
// the dev server's own start-up check probes: a loopback-only server (Vite's
// default) coexists with a wildcard bind on macOS, so a wildcard bind alone
// would accept a port another worker's server already answers on.
const findFreePort = async (): Promise<number> => {
  for (;;) {
    const port = await askOperatingSystemForPort();

    if (!(await isPortTaken(port))) return port;
  }
};

const delay = async (milliseconds: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });

const waitForServer = async (baseURL: string): Promise<void> => {
  const deadline = Date.now() + SERVER_READY_TIMEOUT_MILLISECONDS;

  while (Date.now() < deadline) {
    try {
      await fetch(baseURL);

      return;
    } catch {
      await delay(SERVER_POLL_INTERVAL_MILLISECONDS);
    }
  }

  throw new Error(`The worker server at ${baseURL} did not answer in time.`);
};

/**
 * Extended Playwright test with an axe-core builder fixture (default tag set:
 * WCAG 2.0/2.1 A and AA) and a worker-scoped server fixture for database
 * isolation.
 *
 * Worker isolation. Every worker reaches its own database through the server
 * it talks to, so a spec that seeds a database proves something only against
 * the server that reads it. `workerServer` starts this tree's `pnpm dev` on a
 * free port with a per-worker file database under `.playwright/output/`,
 * passes that file to the process as `DATABASE_URL` (the project's database
 * module reads it), and stops only what it started. It is keyed on
 * `workerInfo.parallelIndex`, which stays stable when a worker restarts after
 * a failure, so a restarted worker lands on the same file. It is lazy: a
 * fixture nothing requests never runs, so the stock suite starts no extra
 * server and `pnpm pw` is unchanged.
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
 *   database under this tree's output folder is already unique to the tree.
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
      const port = await findFreePort();
      const baseURL = `http://localhost:${port}`;
      const databaseFile = path.join(
        packageDirectory,
        '.playwright',
        'output',
        `worker-${workerInfo.parallelIndex}.sqlite`
      );

      fs.mkdirSync(path.dirname(databaseFile), {recursive: true});
      fs.rmSync(databaseFile, {force: true});

      // eslint-disable-next-line sonarjs/no-os-command-from-path -- the harness runs the project's own `pnpm dev`; `pnpm` is the only PATH lookup
      const server = spawn('pnpm', ['dev'], {
        cwd: packageDirectory,
        detached: true,
        env: {
          ...process.env,
          DATABASE_URL: databaseFile,
          [DEV_PORT_OVERRIDE_ENV]: String(port),
          SITE_URL: baseURL,
        },
        stdio: 'ignore',
      });

      const serverStopped = new Promise<never>((_, reject) => {
        server.once('error', reject);
        server.once('exit', (code, signal) => {
          reject(
            new Error(
              `The worker server exited before it answered (code ${code}, signal ${signal}).`
            )
          );
        });
      });

      try {
        await Promise.race([waitForServer(baseURL), serverStopped]);
        await provide({baseURL, databaseFile});
      } finally {
        if (server.pid !== undefined) {
          // The group, so the dev server behind `pnpm` stops with it.
          try {
            process.kill(-server.pid, 'SIGTERM');
          } catch {
            // Already gone.
          }
        }
      }
    },
    {
      scope: 'worker',
      timeout:
        SERVER_READY_TIMEOUT_MILLISECONDS + SERVER_STARTUP_MARGIN_MILLISECONDS,
    },
  ],
});

export {expect};
