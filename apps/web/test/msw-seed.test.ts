import {afterAll, beforeAll, describe, expect, test, vi} from 'vitest';
import type {IncomingMessage, ServerResponse} from 'node:http';
import http from 'node:http';
import type {AddressInfo} from 'node:net';
import {seedRecords} from '../.playwright/msw-seed';
import {
  NETWORK_ERROR_URL,
  SEED_FIXTURE_ORIGIN,
} from './msw-seed/fixture-service';
import {mswSeedPlugin} from './msw-seed/plugin';
import {MSW_SEED_PREFIX} from './msw-seed/protocol';

type Middleware = (
  request: IncomingMessage,
  response: ServerResponse,
  next: () => void
) => void;

// The modules the plugin loads through the dev server's SSR module runner,
// loaded here through Vitest's own, so the seed and forward endpoints share
// one store as they do on a dev server. The real-server proof that the
// runner's instances are the ones the app serves with is the Playwright check
// in `.playwright/e2e/msw-seed/`.
const SSR_MODULES: Record<string, () => Promise<unknown>> = {
  '/test/mocks/database.ts': async () => import('./mocks/database'),
  '/test/mocks/index.ts': async () => import('./mocks'),
  '/test/msw-seed/fixture-service.ts': async () =>
    import('./msw-seed/fixture-service'),
};

const notFound = (response: ServerResponse) => {
  response.writeHead(404);
  response.end();
};

// Serves the plugin's middleware from this process, mounted the way Vite's
// connect stack mounts it: under its prefix, with the prefix stripped from
// the URL the middleware reads.
const startSeedSurface = async (): Promise<http.Server> => {
  let mount: undefined | {handler: Middleware; prefix: string};
  const developmentServer = {
    environments: {
      ssr: {runner: {import: async (url: string) => SSR_MODULES[url]()}},
    },
    middlewares: {
      use: (prefix: string, handler: Middleware) => {
        mount = {handler, prefix};
      },
    },
  };

  (mswSeedPlugin().configureServer as (server: unknown) => void)(
    developmentServer
  );

  const server = http.createServer((request, response) => {
    if (mount === undefined || !request.url?.startsWith(mount.prefix)) {
      notFound(response);

      return;
    }

    request.url = request.url.slice(mount.prefix.length) || '/';
    mount.handler(request, response, () => notFound(response));
  });

  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', resolve);
  });

  return server;
};

let seedSurface: http.Server;
let baseURL: string;

beforeAll(async () => {
  vi.stubEnv('MSW_SEED_FIXTURE', 'true');
  seedSurface = await startSeedSurface();
  baseURL = `http://127.0.0.1:${(seedSurface.address() as AddressInfo).port}`;
});

afterAll(async () => {
  vi.unstubAllEnvs();
  await new Promise((resolve) => {
    seedSurface.close(resolve);
  });
});

const forward = async (targetUrl: string): Promise<Response> =>
  fetch(`${baseURL}${MSW_SEED_PREFIX}/forward`, {
    headers: {'x-gaia-msw-method': 'GET', 'x-gaia-msw-url': targetUrl},
    method: 'POST',
  });

describe('the MSW seed surface', () => {
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
