import {Collection} from '@msw/data';
import {http, HttpResponse} from 'msw/http';
import {z} from 'zod';

// A test-only mock service for the seed surface's own tests: the stock app has
// no collection until the first `/new-service`. The seed plugin adds it only
// when the worker server runs with `MSW_SEED_FIXTURE=true`.

/** The origin its handler answers on, cross-origin like a project's API. */
export const SEED_FIXTURE_ORIGIN = 'https://seed-fixture.test';

/** Starts a worker server's dev server with this service added. */
export const FIXTURE_DEV_COMMAND = [
  'env',
  'MSW_SEED_FIXTURE=true',
  'pnpm',
  'dev',
];

const seedFixtureSchema = z.object({
  id: z.string(),
  name: z.string(),
  quantity: z.int(),
});

export const collections = {
  seedFixtures: new Collection({schema: seedFixtureSchema}),
};

/** The record the store holds before any Given builder seeds one. */
export const BASELINE_SEED_FIXTURE = {
  id: 'baseline-seed-fixture',
  name: 'Hammer',
  quantity: 1,
};

// Empty until this runs, the way a project's collections hold their baseline
// only after `resetTestData`.
export const resetTestData = async (): Promise<void> => {
  collections.seedFixtures.clear();
  await collections.seedFixtures.create(BASELINE_SEED_FIXTURE);
};

export const NETWORK_ERROR_URL = `${SEED_FIXTURE_ORIGIN}/network-error`;

export const handlers = [
  http.get(NETWORK_ERROR_URL, () => HttpResponse.error()),
  http.get(`${SEED_FIXTURE_ORIGIN}/seed-fixtures`, () =>
    HttpResponse.json({data: collections.seedFixtures.findMany()})
  ),
];
