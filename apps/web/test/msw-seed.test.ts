import {afterAll, beforeAll, describe, expect, test} from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {seedRecords} from '../.playwright/msw-seed';
import type {WorkerServer} from '../.playwright/worker-server';
import {startWorkerServer} from '../.playwright/worker-server';
import {
  FIXTURE_DEV_COMMAND,
  SEED_FIXTURE_ORIGIN,
} from './msw-seed/fixture-service';
import {mswSeedPlugin} from './msw-seed/plugin';
import {MSW_SEED_PREFIX} from './msw-seed/protocol';

const packageDirectory = fileURLToPath(new URL('..', import.meta.url));

// Three real dev servers start one after another under the start lock.
const START_ALL_TIMEOUT_MILLISECONDS = 180_000;

const startedServers: WorkerServer[] = [];
let outputDirectory: string;
let firstWorker: WorkerServer;
let secondWorker: WorkerServer;
let ungatedServer: WorkerServer;

const forward = async (
  server: WorkerServer,
  targetUrl: string
): Promise<Response> =>
  fetch(`${server.baseURL}${MSW_SEED_PREFIX}/forward`, {
    headers: {'x-gaia-msw-method': 'GET', 'x-gaia-msw-url': targetUrl},
    method: 'POST',
  });

const listFixtures = async (server: WorkerServer): Promise<unknown> => {
  const response = await forward(
    server,
    `${SEED_FIXTURE_ORIGIN}/seed-fixtures`
  );

  return ((await response.json()) as {data: unknown}).data;
};

beforeAll(async () => {
  outputDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'msw-seed-'));

  const start = async (parallelIndex: number, command: string[]) => {
    const server = await startWorkerServer({
      command,
      outputDirectory,
      packageDirectory,
      parallelIndex,
    });

    startedServers.push(server);

    return server;
  };

  // `env` sets the fixture flag on the spawned dev server alone.
  firstWorker = await start(0, FIXTURE_DEV_COMMAND);
  secondWorker = await start(1, FIXTURE_DEV_COMMAND);
  ungatedServer = await start(2, [
    'env',
    'MSW_SEED=false',
    ...FIXTURE_DEV_COMMAND.slice(1),
  ]);
}, START_ALL_TIMEOUT_MILLISECONDS);

afterAll(() => {
  for (const server of startedServers) server.stop();
  fs.rmSync(outputDirectory, {force: true, recursive: true});
});

describe('the MSW seed surface', () => {
  test('a seeded record is served back by the same worker server', async () => {
    const id = crypto.randomUUID();
    const created = await seedRecords(firstWorker.baseURL, 'seedFixtures', [
      {id, name: 'Wrench', quantity: 3},
    ]);

    expect(created).toEqual([{id, name: 'Wrench', quantity: 3}]);
    expect(await listFixtures(firstWorker)).toContainEqual({
      id,
      name: 'Wrench',
      quantity: 3,
    });
  });

  test('a record seeded on one worker is absent from another worker', async () => {
    const id = crypto.randomUUID();

    await seedRecords(firstWorker.baseURL, 'seedFixtures', [
      {id, name: 'Hammer', quantity: 1},
    ]);

    expect(await listFixtures(secondWorker)).not.toContainEqual(
      expect.objectContaining({id})
    );
  });

  test('a record that does not match the server schema fails naming its collection, index and field', async () => {
    await expect(
      seedRecords(firstWorker.baseURL, 'seedFixtures', [
        {id: crypto.randomUUID(), name: 'Saw', quantity: 2},
        {id: crypto.randomUUID(), name: 'Drill', quantity: 'two'},
      ])
    ).rejects.toThrow(
      /^Seed seedFixtures\[1\] does not match the server schema: quantity: /u
    );
  });

  test('an unknown collection fails naming the collections it has', async () => {
    await expect(
      seedRecords(firstWorker.baseURL, 'seedFixture', [{}])
    ).rejects.toThrow(
      'No collection "seedFixture" in test/mocks/database.ts; it has: seedFixtures.'
    );
  });

  test('a request no handler matches is reported as unhandled', async () => {
    const response = await forward(firstWorker, 'https://unmocked.test/x');

    expect(response.status).toBe(204);
    expect(response.headers.get('x-gaia-msw-unhandled')).toBe('true');
  });

  test('a dev server started without MSW_SEED exposes no seed surface', async () => {
    const response = await fetch(
      `${ungatedServer.baseURL}${MSW_SEED_PREFIX}/seed`,
      {
        body: JSON.stringify({collection: 'seedFixtures', records: []}),
        headers: {'content-type': 'application/json'},
        method: 'POST',
      }
    );

    expect(response.ok).toBe(false);
  });
});

describe('mswSeedPlugin', () => {
  type ApplyHook = (config: unknown, environment: {command: string}) => boolean;

  const apply = mswSeedPlugin().apply as ApplyHook;

  test('applies only to a dev server started with MSW_SEED=true', () => {
    const previous = process.env.MSW_SEED;

    try {
      process.env.MSW_SEED = 'true';
      expect(apply({}, {command: 'serve'})).toBe(true);
      expect(apply({}, {command: 'build'})).toBe(false);
      process.env.MSW_SEED = 'false';
      expect(apply({}, {command: 'serve'})).toBe(false);
    } finally {
      if (previous === undefined) delete process.env.MSW_SEED;
      else process.env.MSW_SEED = previous;
    }
  });
});
