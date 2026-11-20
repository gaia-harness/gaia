import {afterEach, describe, expect, test, vi} from 'vitest';

const importFailureMessage = async (): Promise<string | undefined> => {
  vi.resetModules();

  return import('~/env.server').then(
    () => undefined,
    (error: Error) => error.message
  );
};

const refusal = 'SESSION_SECRET must be at least 32 characters in production';

describe('env.server', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  test.each([
    {
      check: (message: string | undefined) => {
        expect(message).toContain(refusal);
      },
      length: 31,
      outcome: 'refused',
    },
    {
      check: (message: string | undefined) => {
        expect(message).toBeUndefined();
      },
      length: 32,
      outcome: 'accepted',
    },
  ])(
    'SESSION_SECRET length in production is refused below 32 and accepted at 32: a $length-character secret is $outcome',
    async ({check, length}) => {
      vi.stubEnv('NODE_ENV', 'production');
      vi.stubEnv('SESSION_SECRET', 'x'.repeat(length));

      check(await importFailureMessage());
    }
  );

  test('a short production SESSION_SECRET reports beside another invalid variable', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('SESSION_SECRET', 'short');
    vi.stubEnv('API_URL', undefined);

    const message = await importFailureMessage();

    expect(message).toContain(refusal);
    expect(message).toContain('API_URL');
  });
});
