import type {RequestHandler} from 'msw';
import {getResponse} from 'msw';
import type {Plugin, ViteDevServer} from 'vite';
import type {IncomingMessage, ServerResponse} from 'node:http';
import {buffer} from 'node:stream/consumers';
import {
  FORWARD_METHOD_HEADER,
  FORWARD_URL_HEADER,
  MSW_SEED_PREFIX,
  NETWORK_ERROR_HEADER,
  UNHANDLED_HEADER,
} from './protocol.ts';
import type {SeedIssue} from './protocol.ts';

type MockSet = {
  collections: Record<string, SeedCollection>;
  handlers: RequestHandler[];
};

type SeedCollection = {
  create: (record: unknown) => Promise<unknown>;
  // @msw/data keeps the schema it was given here; it is TypeScript-private,
  // not `#private`, so it is reachable at runtime. The seed tests fail if a
  // version moves it.
  options: {schema: StandardSchema};
};

// The slice of the Standard Schema interface (`~standard.validate`) that
// @msw/data validates through, so no schema library is imported here.
type StandardIssue = {
  message: string;
  path?: readonly (PropertyKey | {key: PropertyKey})[];
};

type StandardSchema = {
  '~standard': {
    validate: (
      value: unknown
    ) =>
      | Promise<{issues?: readonly StandardIssue[]}>
      | {issues?: readonly StandardIssue[]};
  };
};

// Loaded through the SSR environment's module runner, the runner React Router
// serves the app with, so the collections and handlers here are the same
// module instances the server's MSW network reads and writes.
const loadMocks = async (server: ViteDevServer): Promise<MockSet> => {
  const {runner} = server.environments.ssr as unknown as {
    runner: {import: <T>(url: string) => Promise<T>};
  };
  const [database, handlers] = await Promise.all([
    runner.import<{default: Record<string, SeedCollection>}>(
      '/test/mocks/database.ts'
    ),
    runner.import<{default: RequestHandler[]}>('/test/mocks/index.ts'),
  ]);
  const mocks = {
    collections: {...database.default},
    handlers: [...handlers.default],
  };

  if (process.env.MSW_SEED_FIXTURE === 'true') {
    const fixture = await runner.import<MockSet>(
      '/test/msw-seed/fixture-service.ts'
    );

    Object.assign(mocks.collections, fixture.collections);
    mocks.handlers.push(...fixture.handlers);
  }

  return mocks;
};

const sendJson = (
  response: ServerResponse,
  status: number,
  body: unknown
): void => {
  response.writeHead(status, {'content-type': 'application/json'});
  response.end(JSON.stringify(body));
};

const formatPath = (issue: StandardIssue): string =>
  (issue.path ?? [])
    .map((segment) =>
      String(typeof segment === 'object' ? segment.key : segment)
    )
    .join('.');

const seed = async (
  server: ViteDevServer,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  const rawBody = await buffer(request);
  const {collection: name, records} = JSON.parse(rawBody.toString('utf8')) as {
    collection: string;
    records: unknown[];
  };
  const {collections} = await loadMocks(server);

  // Own keys only, so a name such as `constructor` never reads an inherited
  // member.
  if (!Object.hasOwn(collections, name)) {
    sendJson(response, 400, {
      error: `No collection "${name}" in test/mocks/database.ts; it has: ${Object.keys(collections).join(', ') || 'none'}.`,
    });

    return;
  }

  const collection = collections[name];

  // Every record is checked before any is created, so a bad batch seeds
  // nothing, and the error names the field @msw/data would only log.
  const validationResults = await Promise.all(
    records.map(async (record) =>
      collection.options.schema['~standard'].validate(record)
    )
  );
  const index = validationResults.findIndex(
    (validationResult) => validationResult.issues !== undefined
  );

  if (index !== -1) {
    const issues: SeedIssue[] = (validationResults[index].issues ?? []).map(
      (issue) => ({
        message: issue.message,
        path: formatPath(issue),
      })
    );

    sendJson(response, 400, {collection: name, index, issues});

    return;
  }

  const created = await Promise.all(
    records.map(async (record) => collection.create(record))
  );

  sendJson(response, 201, created);
};

const HOP_HEADERS = new Set([
  'connection',
  'content-length',
  FORWARD_METHOD_HEADER,
  FORWARD_URL_HEADER,
  'host',
]);

const forward = async (
  server: ViteDevServer,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  const method = String(request.headers[FORWARD_METHOD_HEADER] ?? 'GET');
  const headers = new Headers();

  for (const [name, value] of Object.entries(request.headers)) {
    if (!HOP_HEADERS.has(name) && value !== undefined) {
      headers.set(name, Array.isArray(value) ? value.join(', ') : value);
    }
  }

  const body = await buffer(request);
  const forwarded = new Request(String(request.headers[FORWARD_URL_HEADER]), {
    body:
      method === 'GET' || method === 'HEAD' ? undefined : new Uint8Array(body),
    headers,
    method,
  });
  const {handlers} = await loadMocks(server);
  const mocked = await getResponse(handlers, forwarded);

  if (mocked === undefined) {
    response.writeHead(204, {[UNHANDLED_HEADER]: 'true'});
    response.end();

    return;
  }

  // A network-error response has status 0, which `writeHead` rejects, so the
  // browser handler is told to rebuild it.
  if (mocked.type === 'error') {
    response.writeHead(204, {[NETWORK_ERROR_HEADER]: 'true'});
    response.end();

    return;
  }

  response.writeHead(mocked.status, Object.fromEntries(mocked.headers));
  response.end(Buffer.from(await mocked.arrayBuffer()));
};

const ROUTES = new Map([
  ['/forward', forward],
  ['/seed', seed],
]);

/**
 * Test-only seed surface over the dev server's `@msw/data` store: present only
 * on a dev server started with `MSW_SEED=true`, which only the Playwright
 * worker server sets, so no build and no plain `pnpm dev` carries it.
 */
export const mswSeedPlugin = (): Plugin => ({
  apply: (_, {command}) =>
    command === 'serve' && process.env.MSW_SEED === 'true',
  config: () => ({
    define: {'import.meta.env.GAIA_MSW_SEED': 'true'},
  }),
  configureServer: (server) => {
    server.middlewares.use(MSW_SEED_PREFIX, (request, response, next) => {
      const route = ROUTES.get(request.url ?? '');

      if (route === undefined || request.method !== 'POST') {
        next();

        return;
      }

      route(server, request, response).catch((error: unknown) => {
        sendJson(response, 500, {error: String(error)});
      });
    });
  },
  name: 'gaia-msw-seed',
});
