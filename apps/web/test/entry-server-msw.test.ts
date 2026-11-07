import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';

// The stock barrel is empty until the first `/new-service`, so the store here
// is the seed fixture service: a real collection with a real `reset*` seed.
// Hoisted so the mock and the assertions share one store: `vi.resetModules`
// keeps a mock's cached factory result but hands a plain import a fresh module.
const fixture = await vi.hoisted(
  async () => import('./msw-seed/fixture-service')
);

vi.mock('./mocks/database', () => ({
  default: fixture.collections,
  resetTestData: fixture.resetTestData,
}));

vi.mock('virtual:msw', () => ({
  network: {configure: () => {}, enable: async () => {}},
}));

// The MSW block runs at module evaluation, so each case evaluates it afresh.
const loadEntryServer = async () => {
  vi.resetModules();
  await import('../app/entry.server');
};

beforeEach(() => {
  vi.stubEnv('MSW_ENABLED', 'true');
  vi.spyOn(console, 'info').mockImplementation(() => {});
  fixture.collections.seedFixtures.clear();
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe('the server entry on an MSW dev server', () => {
  test('a plain MSW dev server holds the baseline records before it serves a request', async () => {
    await loadEntryServer();

    expect(fixture.collections.seedFixtures.findMany()).toEqual([
      fixture.BASELINE_SEED_FIXTURE,
    ]);
  });

  test('a worker server leaves the baseline to the seed plugin', async () => {
    vi.stubEnv('GAIA_MSW_SEED', 'true');

    await loadEntryServer();

    expect(fixture.collections.seedFixtures.findMany()).toEqual([]);
  });
});
