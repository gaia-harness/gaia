import {afterEach, expect, test} from 'vitest';
import {createServer} from 'node:http';
import type {Server} from 'node:http';
import type {AddressInfo} from 'node:net';
import {create} from '..';
import {attempt} from '../helpers';

const originalApiUrl = process.env.API_URL;

let server: Server;

afterEach(async () => {
  process.env.API_URL = originalApiUrl;
  server.closeAllConnections();
  await new Promise((resolve) => {
    server.close(resolve);
  });
});

// A real socket: a mocked Response cannot carry a status outside 200-599.
test('a status outside 200-599 on the snake_case layer resolves through attempt as an HTTP failure', async () => {
  server = createServer((_request, response) => {
    response.writeHead(999, {'Content-Type': 'application/json'});
    response.end('{"error_code":1}');
  });
  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', resolve);
  });
  process.env.API_URL = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

  const [failure] = await attempt(async () =>
    create({isSnakeCaseEnabled: true})('items', {retry: 0})
  );

  expect(failure).toMatchObject({status: 999});
});
