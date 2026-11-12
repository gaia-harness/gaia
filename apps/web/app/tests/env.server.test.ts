import {afterEach, describe, expect, test, vi} from 'vitest';

const importFailureMessage = async (): Promise<string | undefined> => {
  vi.resetModules();

  return import('~/env.server').then(
    () => undefined,
    (error: Error) => error.message
  );
};

describe('env.server', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  test.each([
    {
      expected: 'SESSION_SECRET must be at least 32 characters in production',
      length: 31,
    },
    {expected: undefined, length: 32},
  ])(
    'a $length-character SESSION_SECRET in production fails with: $expected',
    async ({expected, length}) => {
      vi.stubEnv('NODE_ENV', 'production');
      vi.stubEnv('SESSION_SECRET', 'x'.repeat(length));

      await expect(importFailureMessage()).resolves.toBe(expected);
    }
  );
});
