import {afterEach, describe, expect, test, vi} from 'vitest';

// Probe: changes no story's dependency graph.
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

  test('a 31-character SESSION_SECRET in production is refused', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('SESSION_SECRET', 'x'.repeat(31));

    expect(await importFailureMessage()).toContain(refusal);
  });

  test('a 32-character SESSION_SECRET in production is accepted', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('SESSION_SECRET', 'x'.repeat(32));

    expect(await importFailureMessage()).toBeUndefined();
  });

  test('a short production SESSION_SECRET reports beside another invalid variable', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('SESSION_SECRET', 'short');
    vi.stubEnv('API_URL', undefined);

    const message = await importFailureMessage();

    expect(message).toContain(refusal);
    expect(message).toContain('API_URL');
  });
});
