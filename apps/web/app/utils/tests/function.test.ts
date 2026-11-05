import {describe, expect, test} from 'vitest';
import {tryCatch} from '../function';

const sleep = async (durationInMilliseconds: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, durationInMilliseconds);
  });

describe('function utils', () => {
  test('tryCatch async result', async () => {
    expect(
      await tryCatch(async (value: number) => {
        await sleep(100);

        return 10 / value;
      }, 5)
    ).toEqual([undefined, 2]);
  });

  test('tryCatch async error', async () => {
    expect(
      await tryCatch(async () => {
        await sleep(100);

        throw new Error('failed');
      })
    ).toEqual([new Error('failed'), undefined]);
  });

  test('tryCatch sync error', async () => {
    expect(
      tryCatch(() => {
        throw new Error('failed');
      })
    ).toEqual([new Error('failed'), undefined]);
  });

  test('tryCatch preserves falsy sync results as success', () => {
    expect(tryCatch(() => 0)).toEqual([undefined, 0]);
    expect(tryCatch(() => false)).toEqual([undefined, false]);
    expect(tryCatch(() => '')).toEqual([undefined, '']);
    expect(tryCatch(() => null)).toEqual([undefined, null]);
  });

  test.each([null, 0, ''])(
    'tryCatch reports a falsy sync throw (%o) as an error',
    (thrownValue) => {
      expect(
        tryCatch(() => {
          throw thrownValue;
        })
      ).toEqual([thrownValue, undefined]);
    }
  );
});
