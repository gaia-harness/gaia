import {delay} from 'msw';
import {http, HttpResponse} from 'msw/http';
import {afterEach, describe, expect, expectTypeOf, test, vi} from 'vitest';
import {z} from 'zod';
import {createServer} from 'node:http';
import type {Server} from 'node:http';
import type {AddressInfo} from 'node:net';
import {create} from '..';
// eslint-disable-next-line no-restricted-imports -- the service layer's request tests register per-test MSW handlers on the suite's node server
import {server} from '../../../../test/test.server';
import {attempt} from '../helpers';

const ORIGIN_A = 'https://api-a.test';
const ORIGIN_B = 'https://api-b.test';

const itemSchema = z.object({displayName: z.string()});
const envelopeSchema = z.object({data: itemSchema});

const parseJsonOrPlainText = (text: string): unknown =>
  text === 'not json' ? {display_name: 'parsed'} : JSON.parse(text);

const originalApiUrl = process.env.API_URL;

afterEach(() => {
  process.env.API_URL = originalApiUrl;
});

describe('create', () => {
  test('resolves the schema output for a valid envelope', async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(
      http.get(`${ORIGIN_A}/items`, () =>
        HttpResponse.json({data: {displayName: 'x'}})
      )
    );

    const request = create();
    const parsedEnvelope = await request('items', {schema: envelopeSchema});

    expect(parsedEnvelope).toEqual({data: {displayName: 'x'}});
    expectTypeOf(parsedEnvelope).toEqualTypeOf<{data: {displayName: string}}>();
  });

  test('a 200 body that violates the schema resolves through attempt as a 500', async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(
      http.get(`${ORIGIN_A}/items`, () => HttpResponse.json({data: {nope: 1}}))
    );

    const request = create();
    const attemptOutcome = await attempt(async () =>
      request('items', {schema: envelopeSchema})
    );

    expect(attemptOutcome).toEqual([
      {status: 500, statusText: 'Response failed schema validation'},
      undefined,
    ]);
  });

  test('a network failure resolves through attempt as a 503', async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(http.get(`${ORIGIN_A}/items`, () => HttpResponse.error()));

    const request = create();
    const attemptOutcome = await attempt(async () =>
      request('items', {retry: 0})
    );

    expect(attemptOutcome).toEqual([
      {isNetworkFailure: true, status: 503, statusText: 'Network error'},
      undefined,
    ]);
  });

  test('a timeout resolves through attempt as a 504', async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(
      http.get(`${ORIGIN_A}/items`, async () => {
        await delay(200);

        return HttpResponse.json({data: {displayName: 'x'}});
      })
    );

    const request = create();
    const attemptOutcome = await attempt(async () =>
      request('items', {retry: 0, schema: envelopeSchema, timeout: 20})
    );

    expect(attemptOutcome).toEqual([
      {isNetworkFailure: true, status: 504, statusText: 'Request timed out'},
      undefined,
    ]);
  });

  test('a cancelled request still rejects through attempt', async () => {
    process.env.API_URL = ORIGIN_A;

    const request = create();

    await expect(
      attempt(async () =>
        request('items', {retry: 0, signal: AbortSignal.abort()})
      )
    ).rejects.toMatchObject({name: 'AbortError'});
  });

  test('a 204 without a schema resolves undefined', async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(
      http.delete(
        `${ORIGIN_A}/items/1`,
        () => new HttpResponse(null, {status: 204})
      )
    );

    const request = create();

    await expect(
      request('items/1', {method: 'delete'})
    ).resolves.toBeUndefined();
  });

  test('a 204 without a schema resolves undefined on the snake_case layer', async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(
      http.delete(
        `${ORIGIN_A}/items/1`,
        () => new HttpResponse(null, {status: 204})
      )
    );

    await expect(
      create({isSnakeCaseEnabled: true})('items/1', {method: 'delete'})
    ).resolves.toBeUndefined();
  });

  test('a 200 with a non-JSON body delivers null on the snake_case layer', async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(
      http.get(`${ORIGIN_A}/items`, () => HttpResponse.text('not json'))
    );

    await expect(
      create({isSnakeCaseEnabled: true})('items', {schema: z.null()})
    ).resolves.toBeNull();
  });

  test("a caller's parseJson still parses the body on the snake_case layer", async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(
      http.get(`${ORIGIN_A}/items`, () => HttpResponse.text('not json'))
    );

    const item = await create({
      isSnakeCaseEnabled: true,
      parseJson: parseJsonOrPlainText,
    })('items', {schema: itemSchema});

    expect(item).toEqual({displayName: 'parsed'});
  });

  test('isSnakeCaseEnabled converts a JSON body to snake_case and the response to camelCase', async () => {
    process.env.API_URL = ORIGIN_A;
    let received: unknown;
    server.use(
      http.post(`${ORIGIN_A}/items`, async ({request}) => {
        received = await request.json();

        return HttpResponse.json({data: {display_name: 'x'}});
      })
    );

    const request = create({isSnakeCaseEnabled: true});
    const parsedEnvelope = await request('items', {
      json: {displayName: 'x'},
      method: 'post',
      schema: envelopeSchema,
    });

    expect(received).toEqual({display_name: 'x'});
    expect(parsedEnvelope.data.displayName).toBe('x');
  });

  test('a snake_case layer sends a non-JSON body unchanged', async () => {
    process.env.API_URL = ORIGIN_A;
    let receivedBody: string | undefined;
    server.use(
      http.post(`${ORIGIN_A}/items`, async ({request}) => {
        receivedBody = await request.text();

        return new HttpResponse(null, {status: 204});
      })
    );

    await create({isSnakeCaseEnabled: true})('items', {
      body: 'plain text body',
      method: 'post',
    });

    expect(receivedBody).toBe('plain text body');
  });

  test('a snake_case layer runs the caller hooks and still snake_cases the JSON body', async () => {
    process.env.API_URL = ORIGIN_A;
    let receivedBody: unknown;
    let receivedHeader: null | string = null;
    server.use(
      http.post(`${ORIGIN_A}/items`, async ({request}) => {
        receivedBody = await request.json();
        receivedHeader = request.headers.get('X-Caller-Hook');

        return HttpResponse.json({});
      })
    );
    const customAfter = vi.fn();

    await create({
      hooks: {
        afterResponse: [customAfter],
        beforeRequest: [
          ({request}) => {
            request.headers.set('X-Caller-Hook', 'ran');
          },
        ],
      },
      isSnakeCaseEnabled: true,
    })('items', {json: {displayName: 'x'}, method: 'post'});

    expect(receivedHeader).toBe('ran');
    expect(receivedBody).toEqual({display_name: 'x'});
    expect(customAfter).toHaveBeenCalledExactlyOnceWith(
      expect.objectContaining({response: expect.any(Response)})
    );
  });

  test('leaves the body and response keys unchanged by default', async () => {
    process.env.API_URL = ORIGIN_A;
    let received: unknown;
    server.use(
      http.post(`${ORIGIN_A}/items`, async ({request}) => {
        received = await request.json();

        return HttpResponse.json({data: {displayName: 'x'}});
      })
    );

    const request = create();
    const parsedEnvelope = await request('items', {
      json: {displayName: 'x'},
      method: 'post',
      schema: envelopeSchema,
    });

    expect(received).toEqual({displayName: 'x'});
    expect(parsedEnvelope.data.displayName).toBe('x');
  });

  test.each([
    {
      expected: '?item_ids=1,2',
      name: 'snake_cases keys when enabled and comma-joins arrays by default',
      options: {isSnakeCaseEnabled: true},
    },
    {
      expected: '?itemIds=1&itemIds=2',
      name: 'honors an explicit arrayFormat',
      options: {arrayFormat: 'none'},
    },
  ] as const)('search params $name', async ({expected, options}) => {
    process.env.API_URL = ORIGIN_A;
    let observedSearch: string | undefined;
    server.use(
      http.get(`${ORIGIN_A}/items`, ({request}) => {
        observedSearch = new URL(request.url).search;

        return HttpResponse.json({});
      })
    );

    await create(options)('items', {searchParams: {itemIds: [1, 2]}});

    expect(decodeURIComponent(observedSearch ?? '')).toBe(expected);
  });

  test('resolves the base URL on every request', async () => {
    const observed: string[] = [];
    server.use(
      http.get(`${ORIGIN_A}/items`, ({request}) => {
        observed.push(request.url);

        return HttpResponse.json({data: {displayName: 'a'}});
      }),
      http.get(`${ORIGIN_B}/items`, ({request}) => {
        observed.push(request.url);

        return HttpResponse.json({data: {displayName: 'b'}});
      })
    );

    const request = create();

    process.env.API_URL = ORIGIN_A;
    await request('items', {schema: envelopeSchema});
    process.env.API_URL = ORIGIN_B;
    await request('items', {schema: envelopeSchema});

    expect(observed).toHaveLength(2);
    expect(observed[0]).toMatch(new RegExp(`^${ORIGIN_A}`));
    expect(observed[1]).toMatch(new RegExp(`^${ORIGIN_B}`));
  });
});

describe('a failure while reading the body', () => {
  const networkFailure = {
    isNetworkFailure: true,
    status: 503,
    statusText: 'Network error',
  };

  let socketServer: Server;

  // A real socket: the headers go out, then the body drops, never ends, or runs
  // over the size limit, so the error comes from a real read, not a mock.
  const startSocketServer = async (
    behavior: 'drop' | 'oversized' | 'stall',
    status = 200
  ) => {
    socketServer = createServer((_request, response) => {
      if (behavior === 'oversized') {
        response.writeHead(status, {'Content-Type': 'application/json'});
        response.end(`"${'x'.repeat(100)}"`);

        return;
      }

      response.writeHead(status, {
        'Content-Length': '100',
        'Content-Type': 'application/json',
      });
      response.write('{"data"');

      if (behavior === 'drop') {
        setTimeout(() => response.destroy(), 20);
      }
    });
    await new Promise<void>((resolve) => {
      socketServer.listen(0, '127.0.0.1', resolve);
    });
    process.env.API_URL = `http://127.0.0.1:${(socketServer.address() as AddressInfo).port}`;
  };

  afterEach(async () => {
    socketServer.closeAllConnections();
    await new Promise((resolve) => {
      socketServer.close(resolve);
    });
  });

  test('a schema-less body that drops resolves through attempt as a 503', async () => {
    await startSocketServer('drop');

    const attemptOutcome = await attempt(async () =>
      create()('items', {retry: 0})
    );

    expect(attemptOutcome).toEqual([networkFailure, undefined]);
  });

  test.each([
    ['the default layer', false],
    ['the snake_case layer', true],
  ])(
    'a schema-less body that stalls on %s resolves through attempt as a 504',
    async (_layer, isSnakeCaseEnabled) => {
      await startSocketServer('stall');

      const attemptOutcome = await attempt(async () =>
        create({isSnakeCaseEnabled})('items', {retry: 0, timeout: 150})
      );

      expect(attemptOutcome).toEqual([
        {isNetworkFailure: true, status: 504, statusText: 'Request timed out'},
        undefined,
      ]);
    }
  );

  test('a body that drops on the snake_case layer resolves through attempt as a 503', async () => {
    await startSocketServer('drop');

    const attemptOutcome = await attempt(async () =>
      create({isSnakeCaseEnabled: true})('items', {retry: 0, schema: z.null()})
    );

    expect(attemptOutcome).toEqual([networkFailure, undefined]);
  });

  test('a 404 whose body drops on the snake_case layer keeps its status through attempt', async () => {
    await startSocketServer('drop', 404);

    const [error] = await attempt(async () =>
      create({isSnakeCaseEnabled: true})('items', {retry: 0, schema: z.null()})
    );

    expect(error).toMatchObject({status: 404});
    expect(error).not.toHaveProperty('isNetworkFailure');
  });

  test('a body over maxResponseSize on the snake_case layer still rejects through attempt', async () => {
    await startSocketServer('oversized');

    await expect(
      attempt(async () =>
        create({isSnakeCaseEnabled: true})('items', {
          maxResponseSize: 10,
          retry: 0,
          schema: z.null(),
        })
      )
    ).rejects.toMatchObject({name: 'ResponseSizeError'});
  });

  test('a body read cancelled on the snake_case layer still rejects through attempt', async () => {
    await startSocketServer('stall');

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
});
