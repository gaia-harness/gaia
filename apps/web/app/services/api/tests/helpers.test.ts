import {HTTPError} from 'ky';
import {describe, expect, test} from 'vitest';
import type {ZodError} from 'zod';
import {z} from 'zod';
import {attempt} from '../helpers';

describe('attempt', () => {
  test('HTTPError: resolves to [{status, statusText}, undefined]', async () => {
    const response = new Response('', {status: 404, statusText: 'Not Found'});
    const request = new Request('https://example.test');
    const httpError = new HTTPError(response, request, {} as never);

    const attemptOutcome = await attempt(async () => {
      throw httpError;
    });

    expect(attemptOutcome).toEqual([
      {status: 404, statusText: 'Not Found'},
      undefined,
    ]);
  });

  test('ZodError: resolves to a constant statusText that carries no issue text', async () => {
    let zodError: ZodError;

    try {
      z.literal(['secret-option']).parse(123);
    } catch (error) {
      zodError = error as ZodError;
    }

    const attemptOutcome = await attempt(async () => {
      throw zodError!;
    });

    expect(attemptOutcome).toEqual([
      {status: 500, statusText: 'Response failed schema validation'},
      undefined,
    ]);
    expect(zodError!.message).toContain('secret-option');
  });

  test('programming error: rejects', async () => {
    const programmingError = new TypeError('Cannot read properties');

    await expect(
      attempt(async () => {
        throw programmingError;
      })
    ).rejects.toBe(programmingError);
  });

  test.each(['something unexpected', null])(
    'non-Error throw (%o): resolves to [{status: 500, statusText: "Unknown error"}, undefined]',
    async (thrownValue) => {
      const attemptOutcome = await attempt(async () => {
        throw thrownValue;
      });

      expect(attemptOutcome).toEqual([
        {status: 500, statusText: 'Unknown error'},
        undefined,
      ]);
    }
  );
});
