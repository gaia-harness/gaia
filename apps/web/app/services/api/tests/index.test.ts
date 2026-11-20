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

let socketServer: Server | undefined;

// A real socket: the headers go out, then the body drops, never ends, or runs
// over the size limit, so the error comes from a real read, not a mock.
const startSocketServer = async (
  behavior: 'drop' | 'oversized' | 'stall',
  status = 200
): Promise<void> => {
  const startedServer = createServer((_request, response) => {
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
  socketServer = startedServer;
  await new Promise<void>((resolve) => {
    startedServer.listen(0, '127.0.0.1', resolve);
  });
  process.env.API_URL = `http://127.0.0.1:${(startedServer.address() as AddressInfo).port}`;
};

const useMockHandler = (handler: ReturnType<typeof http.get>) => (): void => {
  process.env.API_URL = ORIGIN_A;
  server.use(handler);
};

const useSocketServer =
  (behavior: 'drop' | 'oversized' | 'stall', status?: number) =>
  async (): Promise<void> =>
    startSocketServer(behavior, status);

const fulfilledValue = (settled: PromiseSettledResult<unknown>): unknown => {
  expect(settled.status).toBe('fulfilled');

  return (settled as PromiseFulfilledResult<unknown>).value;
};

const networkFailure = {
  isNetworkFailure: true,
  status: 503,
  statusText: 'Network error',
};

const timedOut = {
  isNetworkFailure: true,
  status: 504,
  statusText: 'Request timed out',
};

const resolvesAs = (error: object) => (attemptOutcome: unknown) => {
  expect(attemptOutcome).toEqual([error, undefined]);
};

afterEach(async () => {
  process.env.API_URL = originalApiUrl;

  if (socketServer) {
    socketServer.closeAllConnections();
    const closingServer = socketServer;
    socketServer = undefined;
    await new Promise((resolve) => {
      closingServer.close(resolve);
    });
  }
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

  test.each(
    [
      {
        arrange: useMockHandler(
          http.get(`${ORIGIN_A}/items`, () =>
            HttpResponse.json({data: {nope: 1}})
          )
        ),
        check: resolvesAs({
          status: 500,
          statusText: 'Response failed schema validation',
        }),
        name: 'a 200 body that violates the schema is a 500',
        request: async () => create()('items', {schema: envelopeSchema}),
      },
      {
        arrange: useMockHandler(
          http.get(`${ORIGIN_A}/items`, () => HttpResponse.error())
        ),
        check: resolvesAs(networkFailure),
        name: 'a network failure is a 503',
        request: async () => create()('items', {retry: 0}),
      },
      {
        arrange: useMockHandler(
          http.get(`${ORIGIN_A}/items`, async () => {
            await delay(200);

            return HttpResponse.json({data: {displayName: 'x'}});
          })
        ),
        check: resolvesAs(timedOut),
        name: 'a timeout is a 504',
        request: async () =>
          create()('items', {retry: 0, schema: envelopeSchema, timeout: 20}),
      },
      {
        arrange: useSocketServer('drop'),
        check: resolvesAs(networkFailure),
        name: 'a schema-less body that drops is a 503',
        request: async () => create()('items', {retry: 0}),
      },
      ...[
        ['the default layer', false],
        ['the snake_case layer', true],
      ].map(([layer, isSnakeCaseEnabled]) => ({
        arrange: useSocketServer('stall'),
        check: resolvesAs(timedOut),
        name: `a schema-less body that stalls on ${layer} is a 504`,
        request: async () =>
          create({isSnakeCaseEnabled: isSnakeCaseEnabled as boolean})('items', {
            retry: 0,
            timeout: 150,
          }),
      })),
      {
        arrange: useSocketServer('stall'),
        check: resolvesAs(timedOut),
        name: 'a body that stalls on the snake_case layer with a schema is a 504',
        request: async () =>
          create({isSnakeCaseEnabled: true})('items', {
            retry: 0,
            schema: z.null(),
            timeout: 150,
          }),
      },
      {
        arrange: useSocketServer('drop'),
        check: resolvesAs(networkFailure),
        name: 'a body that drops on the snake_case layer is a 503',
        request: async () =>
          create({isSnakeCaseEnabled: true})('items', {
            retry: 0,
            schema: z.null(),
          }),
      },
      {
        arrange: useSocketServer('drop', 404),
        check: (attemptOutcome: unknown) => {
          const [error] = attemptOutcome as [object, undefined];

          expect(error).toMatchObject({status: 404});
          expect(error).not.toHaveProperty('isNetworkFailure');
        },
        name: 'a 404 whose body drops on the snake_case layer keeps its status',
        request: async () =>
          create({isSnakeCaseEnabled: true})('items', {
            retry: 0,
            schema: z.null(),
          }),
      },
    ].map((row) => [row.name, row] as const)
  )(
    'a failed request resolves through attempt with its mapped status: %s',
    async (_name, {arrange, check, request}) => {
      await arrange();

      check(await attempt(async () => request()));
    }
  );

  test.each(
    [
      {
        arrange: (): void => {
          process.env.API_URL = ORIGIN_A;
        },
        errorName: 'AbortError',
        name: 'a cancelled request',
        request: async () =>
          create()('items', {retry: 0, signal: AbortSignal.abort()}),
      },
      {
        arrange: useSocketServer('oversized'),
        errorName: 'ResponseSizeError',
        name: 'a body over maxResponseSize on the snake_case layer',
        request: async () =>
          create({isSnakeCaseEnabled: true})('items', {
            maxResponseSize: 10,
            retry: 0,
            schema: z.null(),
          }),
      },
      {
        arrange: useSocketServer('stall'),
        errorName: 'TimeoutError',
        name: 'a body read cancelled on the snake_case layer',
        request: async () =>
          create({isSnakeCaseEnabled: true})('items', {
            retry: 0,
            schema: z.null(),
            signal: AbortSignal.timeout(50),
          }),
      },
    ].map((row) => [row.name, row] as const)
  )(
    'a cancelled or oversized read rejects through attempt: %s',
    async (_name, {arrange, errorName, request}) => {
      await arrange();

      await expect(attempt(async () => request())).rejects.toMatchObject({
        name: errorName,
      });
    }
  );

  test.each(
    [
      {
        expected: undefined,
        handler: http.delete(
          `${ORIGIN_A}/items/1`,
          () => new HttpResponse(null, {status: 204})
        ),
        name: 'a 204 without a schema resolves undefined',
        request: async () => create()('items/1', {method: 'delete'}),
      },
      {
        expected: undefined,
        handler: http.delete(
          `${ORIGIN_A}/items/1`,
          () => new HttpResponse(null, {status: 204})
        ),
        name: 'a 204 without a schema resolves undefined on the snake_case layer',
        request: async () =>
          create({isSnakeCaseEnabled: true})('items/1', {method: 'delete'}),
      },
      {
        expected: null,
        handler: http.get(`${ORIGIN_A}/items`, () =>
          HttpResponse.text('not json')
        ),
        name: 'a 200 with a non-JSON body delivers null on the snake_case layer',
        request: async () =>
          create({isSnakeCaseEnabled: true})('items', {schema: z.null()}),
      },
      {
        expected: undefined,
        handler: http.get(
          `${ORIGIN_A}/items`,
          () => new HttpResponse(null, {status: 200})
        ),
        name: 'an empty 2xx body parses to undefined on the snake_case layer',
        request: async () =>
          create({isSnakeCaseEnabled: true})('items', {
            schema: z.undefined(),
          }),
      },
    ].map((row) => [row.name, row] as const)
  )(
    'an empty or non-JSON success body resolves cleanly on each layer: %s',
    async (_name, {expected, handler, request}) => {
      process.env.API_URL = ORIGIN_A;
      server.use(handler);

      await expect(request()).resolves.toBe(expected);
    }
  );

  describe('the snake_case layer converts bodies and honors caller options', () => {
    type Sent = {header: null | string; text: string};

    const callerAfterResponse = vi.fn();

    test.each(
      [
        {
          name: 'isSnakeCaseEnabled converts a JSON body to snake_case and the response to camelCase',
          register: http.post,
          request: async () =>
            create({isSnakeCaseEnabled: true})('items', {
              json: {displayName: 'x'},
              method: 'post',
              schema: envelopeSchema,
            }),
          respond: () => HttpResponse.json({data: {display_name: 'x'}}),
          verify: (sent: Sent, settled: PromiseSettledResult<unknown>) => {
            expect(JSON.parse(sent.text)).toEqual({display_name: 'x'});
            expect(fulfilledValue(settled)).toMatchObject({
              data: {displayName: 'x'},
            });
          },
        },
        {
          name: 'leaves the body and response keys unchanged by default',
          register: http.post,
          request: async () =>
            create()('items', {
              json: {displayName: 'x'},
              method: 'post',
              schema: envelopeSchema,
            }),
          respond: () => HttpResponse.json({data: {displayName: 'x'}}),
          verify: (sent: Sent, settled: PromiseSettledResult<unknown>) => {
            expect(JSON.parse(sent.text)).toEqual({displayName: 'x'});
            expect(fulfilledValue(settled)).toMatchObject({
              data: {displayName: 'x'},
            });
          },
        },
        {
          name: 'a snake_case layer sends a non-JSON body unchanged',
          register: http.post,
          request: async () =>
            create({isSnakeCaseEnabled: true})('items', {
              body: 'plain text body',
              method: 'post',
            }),
          respond: () => new HttpResponse(null, {status: 204}),
          verify: (sent: Sent, settled: PromiseSettledResult<unknown>) => {
            fulfilledValue(settled);

            expect(sent.text).toBe('plain text body');
          },
        },
        {
          name: 'a snake_case layer runs the caller hooks and still snake_cases the JSON body',
          register: http.post,
          request: async () =>
            create({
              hooks: {
                afterResponse: [callerAfterResponse],
                beforeRequest: [
                  ({request}) => {
                    request.headers.set('X-Caller-Hook', 'ran');
                  },
                ],
              },
              isSnakeCaseEnabled: true,
            })('items', {json: {displayName: 'x'}, method: 'post'}),
          respond: () => HttpResponse.json({}),
          verify: (sent: Sent, settled: PromiseSettledResult<unknown>) => {
            fulfilledValue(settled);

            expect(sent.header).toBe('ran');
            expect(JSON.parse(sent.text)).toEqual({display_name: 'x'});
            expect(callerAfterResponse).toHaveBeenCalledExactlyOnceWith(
              expect.objectContaining({response: expect.any(Response)})
            );
          },
        },
        {
          name: "a caller's parseJson still parses the body on the snake_case layer",
          register: http.get,
          request: async () =>
            create({
              isSnakeCaseEnabled: true,
              parseJson: parseJsonOrPlainText,
            })('items', {schema: itemSchema}),
          respond: () => HttpResponse.text('not json'),
          verify: (_sent: Sent, settled: PromiseSettledResult<unknown>) => {
            expect(fulfilledValue(settled)).toEqual({displayName: 'parsed'});
          },
        },
        {
          name: "a caller's parseJson error propagates on the snake_case layer",
          register: http.get,
          request: async () =>
            create({
              isSnakeCaseEnabled: true,
              parseJson: () => {
                throw new Error('bad data');
              },
            })('items', {schema: z.null()}),
          respond: () => HttpResponse.json({}),
          verify: (_sent: Sent, settled: PromiseSettledResult<unknown>) => {
            expect(settled.status).toBe('rejected');
            expect(
              (settled as PromiseRejectedResult).reason as Error
            ).toHaveProperty('message', expect.stringContaining('bad data'));
          },
        },
      ].map((row) => [row.name, row] as const)
    )(
      'the snake_case layer converts bodies and honors caller options: %s',
      async (_name, {register, request, respond, verify}) => {
        callerAfterResponse.mockClear();
        process.env.API_URL = ORIGIN_A;
        const sent: Sent = {header: null, text: ''};
        server.use(
          register(`${ORIGIN_A}/items`, async (context) => {
            sent.text = await context.request.text();
            sent.header = context.request.headers.get('X-Caller-Hook');

            return respond();
          })
        );

        const [settled] = await Promise.allSettled([request()]);

        verify(sent, settled);
      }
    );
  });

  test.each(
    (
      [
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
      ] as const
    ).map((row) => [row.name, row] as const)
  )('search params %s', async (_name, {expected, options}) => {
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
