import {afterAll, beforeAll, describe, expect, test, vi} from 'vitest';
import type {IncomingMessage, ServerResponse} from 'node:http';
import http from 'node:http';
import type {AddressInfo} from 'node:net';
import {seedRecords} from '../.playwright/msw-seed';
import {
  BASELINE_SEED_FIXTURE,
  collections as fixtureCollections,
  NETWORK_ERROR_URL,
  SEED_FIXTURE_ORIGIN,
} from './msw-seed/fixture-service';
import {mswSeedPlugin} from './msw-seed/plugin';
import {MSW_SEED_PREFIX} from './msw-seed/protocol';

type Middleware = (
  request: IncomingMessage,
  response: ServerResponse,
  next: (error?: unknown) => void
) => void;

type ModuleLoaders = Record<string, () => Promise<unknown>>;

// The modules the plugin loads through the dev server's SSR module runner,
// loaded here through Vitest's own, so the seed and forward endpoints share
// one store as they do on a dev server. The real-server proof that the
// runner's instances are the ones the app serves with is the Playwright check
// in `.playwright/e2e/msw-seed/`.
const SSR_MODULES: ModuleLoaders = {
  '/test/mocks/database.ts': async () => import('./mocks/database'),
  '/test/mocks/index.ts': async () => import('./mocks'),
  '/test/msw-seed/fixture-service.ts': async () =>
    import('./msw-seed/fixture-service'),
};

const APP_PATH = '/app-reads-the-store';

const notFound = (response: ServerResponse) => {
  response.writeHead(404);
  response.end();
};

// Stands in for the app the dev server renders after every middleware: it
// reads the store directly, as a route's mocked API call does, never through
// the seed surface.
const serveApp = (response: ServerResponse) => {
  response.writeHead(200, {'content-type': 'application/json'});
  response.end(
    JSON.stringify({data: fixtureCollections.seedFixtures.findMany()})
  );
};

// Serves the plugin's middleware from this process in the order Vite's
// connect stack runs it: a prefixed mount sees only its own URLs, with the
// prefix stripped, and `next(error)` ends the request as a server error.
const startSeedSurface = async (
  modules: ModuleLoaders = SSR_MODULES
): Promise<http.Server> => {
  const mounts: {handler: Middleware; prefix: string}[] = [];
  const developmentServer = {
    environments: {
      ssr: {runner: {import: async (url: string) => modules[url]()}},
    },
    middlewares: {
      use: (...mount: [Middleware] | [string, Middleware]) => {
        mounts.push(
          mount.length === 1 ?
            {handler: mount[0], prefix: ''}
          : {handler: mount[1], prefix: mount[0]}
        );
      },
    },
  };

  (mswSeedPlugin().configureServer as (server: unknown) => void)(
    developmentServer
  );

  const server = http.createServer((request, response) => {
    const url = request.url ?? '/';

    const run = (index: number, error?: unknown): void => {
      if (error !== undefined) {
        response.writeHead(500);
        response.end(String(error));

        return;
      }

      const mount = mounts.at(index);

      if (mount === undefined) {
        if (url === APP_PATH) serveApp(response);
        else notFound(response);

        return;
      }

      if (!url.startsWith(mount.prefix)) {
        run(index + 1);

        return;
      }

      request.url = url.slice(mount.prefix.length) || '/';
      mount.handler(request, response, (nextError) => {
        request.url = url;
        run(index + 1, nextError);
      });
    };

    run(0);
  });

  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', resolve);
  });

  return server;
};

const urlOf = (server: http.Server): string =>
  `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

const closeSurface = async (server: http.Server): Promise<void> =>
  new Promise((resolve) => {
    server.close(() => resolve());
  });

let seedSurface: http.Server;
let baseURL: string;

beforeAll(async () => {
  vi.stubEnv('MSW_SEED_FIXTURE', 'true');
  seedSurface = await startSeedSurface();
  baseURL = urlOf(seedSurface);
});

afterAll(async () => {
  vi.unstubAllEnvs();
  await closeSurface(seedSurface);
});

const forward = async (targetUrl: string): Promise<Response> =>
  fetch(`${baseURL}${MSW_SEED_PREFIX}/forward`, {
    headers: {'x-gaia-msw-method': 'GET', 'x-gaia-msw-url': targetUrl},
    method: 'POST',
  });

describe('the MSW seed surface', () => {
  // First in the file: the shared surface must not have served a request yet.
  test('the app reads the resetTestData baseline on its first request, before any seed call', async () => {
    const response = await fetch(`${baseURL}${APP_PATH}`);

    expect(((await response.json()) as {data: unknown}).data).toEqual([
      BASELINE_SEED_FIXTURE,
    ]);
  });

  test('a seeded record is served back through the forward endpoint', async () => {
    const id = crypto.randomUUID();
    const created = await seedRecords(baseURL, 'seedFixtures', [
      {id, name: 'Wrench', quantity: 3},
    ]);
    const response = await forward(`${SEED_FIXTURE_ORIGIN}/seed-fixtures`);

    expect(created).toEqual([{id, name: 'Wrench', quantity: 3}]);
    expect(((await response.json()) as {data: unknown}).data).toContainEqual({
      id,
      name: 'Wrench',
      quantity: 3,
    });
  });

  test('a record that does not match the server schema fails naming its collection, index and field', async () => {
    await expect(
      seedRecords(baseURL, 'seedFixtures', [
        {id: crypto.randomUUID(), name: 'Saw', quantity: 2},
        {id: crypto.randomUUID(), name: 'Drill', quantity: 'two'},
      ])
    ).rejects.toThrow(
      /^Seed seedFixtures\[1\] does not match the server schema: quantity: /u
    );
  });

  test('an unknown collection fails naming the collections it has', async () => {
    await expect(seedRecords(baseURL, 'seedFixture', [{}])).rejects.toThrow(
      /^No collection "seedFixture" in test\/mocks\/database\.ts; it has: .*\bseedFixtures\b/u
    );
  });

  test('a request no handler matches is reported as unhandled', async () => {
    const response = await forward('https://unmocked.test/x');

    expect(response.status).toBe(204);
    expect(response.headers.get('x-gaia-msw-unhandled')).toBe('true');
  });

  test('a mock that answers a network error is reported as one, not as an HTTP failure', async () => {
    const response = await forward(NETWORK_ERROR_URL);

    expect(response.status).toBe(204);
    expect(response.headers.get('x-gaia-msw-network-error')).toBe('true');
  });
});

describe('a baseline reset that fails', () => {
  test('fails every request as a server error instead of leaving it waiting, and is not retried', async () => {
    const resetTestData = vi.fn(async () => {
      throw new Error('baseline seed broke');
    });
    const surface = await startSeedSurface({
      ...SSR_MODULES,
      '/test/mocks/database.ts': async () => ({default: {}, resetTestData}),
    });

    try {
      // Bounded: a first-request gate that never settles would hang every
      // request instead of failing it.
      const signal = AbortSignal.timeout(2000);
      const first = await fetch(`${urlOf(surface)}${APP_PATH}`, {signal});
      const second = await fetch(`${urlOf(surface)}${APP_PATH}`, {signal});

      expect([first.status, second.status]).toEqual([500, 500]);
      expect(await second.text()).toContain('baseline seed broke');
      expect(resetTestData).toHaveBeenCalledTimes(1);
    } finally {
      await closeSurface(surface);
    }
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
