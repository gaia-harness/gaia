import {describe, expect, test} from 'vitest';
import {tryCatch} from '../function';

const throwing = (thrownValue: unknown) => (): never => {
  throw thrownValue;
};

describe('function utils', () => {
  test.each(
    [
      {
        expected: [undefined, 2],
        isAsync: true,
        name: 'async result',
        run: async () => tryCatch(async (value: number) => 10 / value, 5),
      },
      {
        expected: [new Error('failed'), undefined],
        isAsync: true,
        name: 'async error',
        run: async () =>
          tryCatch(async () => {
            throw new Error('failed');
          }),
      },
      {
        expected: [new Error('failed'), undefined],
        isAsync: false,
        name: 'sync error',
        run: () => tryCatch(throwing(new Error('failed'))),
      },
      ...[0, false, '', null].map((falsyValue) => ({
        expected: [undefined, falsyValue],
        isAsync: false,
        name: `falsy sync result (${JSON.stringify(falsyValue)}) is preserved as success`,
        run: () => tryCatch(() => falsyValue),
      })),
      ...[null, 0, ''].map((thrownValue) => ({
        expected: [thrownValue, undefined],
        isAsync: false,
        name: `falsy sync throw (${JSON.stringify(thrownValue)}) is reported as an error`,
        run: () => tryCatch(throwing(thrownValue)),
      })),
    ].map((row) => [row.name, row] as const)
  )(
    'tryCatch returns [error, result] for each sync and async outcome: %s',
    async (_name, {expected, isAsync, run}) => {
      const outcome = run();

      expect(isAsync ? await outcome : outcome).toEqual(expected);
    }
  );
});
