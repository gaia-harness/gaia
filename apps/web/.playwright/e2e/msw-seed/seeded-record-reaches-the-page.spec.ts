import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {
  FIXTURE_DEV_COMMAND,
  SEED_FIXTURE_ORIGIN,
} from '../../../test/msw-seed/fixture-service';
import type {GivenBuilder} from '../../fixtures';
import {test as base, expect} from '../../fixtures';
import {seedRecords} from '../../msw-seed';
import {hydration} from '../../utils';
import {
  SERVER_READY_TIMEOUT_MILLISECONDS,
  START_LOCK_TIMEOUT_MILLISECONDS,
  startWorkerServer,
} from '../../worker-server';

type SeedFixture = {id: string; name: string; quantity: number};

const packageDirectory = fileURLToPath(new URL('../../..', import.meta.url));

// Its own worker server, started with the test-only fixture service, so the
// stock app needs no collection of its own for this check.
const test = base.extend<
  {givenSeedFixture: GivenBuilder<{name: string}, SeedFixture>},
  {fixtureServer: {baseURL: string}}
>({
  baseURL: async ({fixtureServer}, provide) => provide(fixtureServer.baseURL),
  fixtureServer: [
    async ({}, provide, workerInfo) => {
      const {baseURL, stop} = await startWorkerServer({
        command: FIXTURE_DEV_COMMAND,
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
      timeout:
        START_LOCK_TIMEOUT_MILLISECONDS +
        SERVER_READY_TIMEOUT_MILLISECONDS +
        10_000,
    },
  ],
  givenSeedFixture: async ({fixtureServer}, provide) =>
    provide(async ({name}) => {
      const [created] = await seedRecords<SeedFixture>(
        fixtureServer.baseURL,
        'seedFixtures',
        [{id: crypto.randomUUID(), name, quantity: 1}]
      );

      return created;
    }),
});

// The stock CSP allows only same-origin connections; a project lets its API
// origin through `connect-src`, which this check stands in for.
test.use({bypassCSP: true});

test('a record a Given builder seeded reaches a cross-origin fetch in the page', async ({
  givenSeedFixture,
  page,
}) => {
  const seeded = await givenSeedFixture({name: 'Wrench'});

  await page.goto('/');
  await hydration(page);

  const listed = await page.evaluate(async (origin) => {
    const response = await fetch(`${origin}/seed-fixtures`);

    return ((await response.json()) as {data: unknown[]}).data;
  }, SEED_FIXTURE_ORIGIN);

  expect(listed).toContainEqual(seeded);
});
