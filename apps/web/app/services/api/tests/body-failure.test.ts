import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {z} from 'zod';
import {createServer} from 'node:http';
import type {Server} from 'node:http';
import type {AddressInfo} from 'node:net';
import {create} from '..';
import {attempt} from '../helpers';

type BodyBehavior = 'drop' | 'stall';

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

beforeEach(() => {
  process.env.API_URL = originalApiUrl;
});

afterEach(async () => {
  process.env.API_URL = originalApiUrl;
  server.closeAllConnections();
  await new Promise((resolve) => {
    server.close(resolve);
  });
});

const schema = z.object({data: z.object({displayName: z.string()})});

describe.each([
  {isSnakeCaseEnabled: false, layer: 'plain layer'},
  {isSnakeCaseEnabled: true, layer: 'snake_case layer'},
])('body failure on a $layer', ({isSnakeCaseEnabled}) => {
  test.each([{hasSchema: false}, {hasSchema: true}])(
    'a body that drops resolves through attempt as a 503 (schema: $hasSchema)',
    async ({hasSchema}) => {
      await startServer('drop');
      const request = create({isSnakeCaseEnabled});
      const outcome = await attempt(async () =>
        hasSchema ?
          request('items', {retry: 0, schema})
        : request('items', {retry: 0})
      );

      expect(outcome).toEqual([
        {isNetworkFailure: true, status: 503, statusText: 'Network error'},
        undefined,
      ]);
    }
  );

  test.each([{hasSchema: false}, {hasSchema: true}])(
    'a body that stalls resolves through attempt as a 504 (schema: $hasSchema)',
    async ({hasSchema}) => {
      await startServer('stall');
      const request = create({isSnakeCaseEnabled});
      const outcome = await attempt(async () =>
        hasSchema ?
          request('items', {retry: 0, schema, timeout: 150})
        : request('items', {retry: 0, timeout: 150})
      );

      expect(outcome).toEqual([
        {isNetworkFailure: true, status: 504, statusText: 'Request timed out'},
        undefined,
      ]);
    }
  );
});
