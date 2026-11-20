import {http, HttpResponse} from 'msw/http';
import {afterEach, describe, expect, test, vi} from 'vitest';
import {z} from 'zod';
import {create} from '..';
// eslint-disable-next-line no-restricted-imports -- the service layer's request tests register per-test MSW handlers on the suite's node server
import {server} from '../../../../test/test.server';

const ORIGIN_A = 'https://api-a.test';

const itemSchema = z.object({displayName: z.string()});
const envelopeSchema = z.object({data: itemSchema});

const parseJsonOrPlainText = (text: string): unknown =>
  text === 'not json' ? {display_name: 'parsed'} : JSON.parse(text);

const originalApiUrl = process.env.API_URL;

const fulfilledValue = (settled: PromiseSettledResult<unknown>): unknown => {
  expect(settled.status).toBe('fulfilled');

  return (settled as PromiseFulfilledResult<unknown>).value;
};

afterEach(() => {
  process.env.API_URL = originalApiUrl;
});

describe('create', () => {
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
});
