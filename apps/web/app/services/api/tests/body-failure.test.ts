import {afterEach, expect, test} from 'vitest';
import {z} from 'zod';
import {createServer} from 'node:http';
import type {Server} from 'node:http';
import type {AddressInfo} from 'node:net';
import {create} from '..';
import {attempt} from '../helpers';

type BodyBehavior = 'drop' | 'stall';

const NETWORK_FAILURE = {
  isNetworkFailure: true,
  status: 503,
  statusText: 'Network error',
};

const originalApiUrl = process.env.API_URL;

let server: Server;

// A real socket: the headers go out, then the body drops or never ends, which
// a mocked fetch cannot reproduce.
const startServer = async (behavior: BodyBehavior) => {
  server = createServer((_request, response) => {
    response.writeHead(200, {
      'Content-Length': '100',
      'Content-Type': 'application/json',
    });
    response.write('{"data"');

    if (behavior === 'drop') {
      setTimeout(() => response.destroy(), 20);
    }
  });
  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', resolve);
  });
  process.env.API_URL = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
};

afterEach(async () => {
  process.env.API_URL = originalApiUrl;
  server.closeAllConnections();
  await new Promise((resolve) => {
    server.close(resolve);
  });
});

test('a schema-less body that drops resolves through attempt as a 503', async () => {
  await startServer('drop');

  const outcome = await attempt(async () => create()('items', {retry: 0}));

  expect(outcome).toEqual([NETWORK_FAILURE, undefined]);
});

test('a schema-less body that stalls resolves through attempt as a 504', async () => {
  await startServer('stall');

  const outcome = await attempt(async () =>
    create()('items', {retry: 0, timeout: 150})
  );

  expect(outcome).toEqual([
    {isNetworkFailure: true, status: 504, statusText: 'Request timed out'},
    undefined,
  ]);
});

test('a body that drops on the snake_case layer resolves through attempt as a 503', async () => {
  await startServer('drop');

  const outcome = await attempt(async () =>
    create({isSnakeCaseEnabled: true})('items', {retry: 0, schema: z.null()})
  );

  expect(outcome).toEqual([NETWORK_FAILURE, undefined]);
});

test('a body read cancelled on the snake_case layer still rejects through attempt', async () => {
  await startServer('stall');

  await expect(
    attempt(async () =>
      create({isSnakeCaseEnabled: true})('items', {
        retry: 0,
        schema: z.null(),
        signal: AbortSignal.timeout(50),
      })
    )
  ).rejects.toMatchObject({name: 'TimeoutError'});
});
