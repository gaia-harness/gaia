import {HTTPError} from 'ky';
import {describe, expect, test} from 'vitest';
import type {ZodError} from 'zod';
import {z} from 'zod';
import {attempt} from '../helpers';

const buildHttpError = (): HTTPError =>
  new HTTPError(
    new Response('', {status: 404, statusText: 'Not Found'}),
    new Request('https://example.test'),
    {} as never
  );

const buildZodError = (): ZodError => {
  try {
    z.literal(['secret-option']).parse(123);
  } catch (error) {
    return error as ZodError;
  }

  throw new Error('expected the parse to throw');
};

const noExtraCheck = (): void => {};

describe('attempt', () => {
  test.each(
    [
      {
        buildThrown: buildHttpError,
        expected: {status: 404, statusText: 'Not Found'},
        name: 'an HTTPError keeps its status and statusText',
        verifyThrown: noExtraCheck,
      },
      {
        // The thrown message carries the issue text, the statusText must not.
        buildThrown: buildZodError,
        expected: {
          status: 500,
          statusText: 'Response failed schema validation',
        },
        name: 'a ZodError resolves to a constant statusText that carries no issue text',
        verifyThrown: (thrown: unknown) => {
          expect((thrown as ZodError).message).toContain('secret-option');
        },
      },
      {
        buildThrown: () => 'something unexpected',
        expected: {status: 500, statusText: 'Unknown error'},
        name: 'a thrown string resolves to Unknown error',
        verifyThrown: noExtraCheck,
      },
      {
        buildThrown: () => null,
        expected: {status: 500, statusText: 'Unknown error'},
        name: 'a thrown null resolves to Unknown error',
        verifyThrown: noExtraCheck,
      },
    ].map((row) => [row.name, row] as const)
  )(
    'attempt maps each thrown value to a status tuple: %s',
    async (_name, {buildThrown, expected, verifyThrown}) => {
      const thrown = buildThrown();

      const attemptOutcome = await attempt(async () => {
        throw thrown;
      });

      expect(attemptOutcome).toEqual([expected, undefined]);
      verifyThrown(thrown);
    }
  );

  test('programming error: rejects', async () => {
    const programmingError = new TypeError('Cannot read properties');

    await expect(
      attempt(async () => {
        throw programmingError;
      })
    ).rejects.toBe(programmingError);
  });
});
