import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {run} from './crossing.js';
import {run as runUpdate} from './index.js';

const captured = (): {errors: string[]; outputs: string[]} => {
  const outputs: string[] = [];
  const errors: string[] = [];

  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    outputs.push(String(chunk));

    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
    errors.push(String(chunk));

    return true;
  });

  return {errors, outputs};
};

beforeEach(() => {
  vi.restoreAllMocks();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('crossing router', () => {
  test('prints usage with no verb and through the update router', async () => {
    const sink = captured();

    expect(run([])).toBe(0);
    expect(await runUpdate(['crossing', 'help'])).toBe(0);
    expect(sink.outputs.join('')).toContain('preflight');
    expect(sink.outputs.join('')).toContain('rekey');
  });

  test('an unknown verb exits 1 with a structured error', () => {
    const sink = captured();

    expect(run(['nonsense'])).toBe(1);
    expect(sink.errors.join('')).toContain('unknown_subcommand');
  });

  test.each([
    [['move', '--force']],
    [['rekey']],
    [['rekey', '--baseline-tag']],
    [['preflight', 'extra']],
  ])('%j exits 2', (argv) => {
    const sink = captured();

    expect(run(argv)).toBe(2);
    expect(sink.errors.join('')).toContain('invalid_arguments');
  });
});
