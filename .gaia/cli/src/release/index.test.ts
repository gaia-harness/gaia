import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from '../exit.js';
import {run as runBump} from './bump.js';
import {run} from './index.js';

vi.mock('./bump.js', () => ({run: vi.fn()}));

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

let stdio: ReturnType<typeof captureStdio>;

beforeEach(() => {
  vi.mocked(runBump).mockReset();
  stdio = captureStdio();
});

afterEach(() => {
  stdio.restore();
});

// Read every chunk, not just the first: a lone `calls[0]` read misses a payload
// that arrives in a later write.
const readStderrPayload = (): Record<string, unknown> =>
  JSON.parse(stdio.errors.join('').trim().split('\n').at(-1) ?? '{}') as Record<
    string,
    unknown
  >;

describe('release subcommand router', () => {
  test.each<{args: string[]; name: string}>([
    {args: ['--help'], name: '--help prints help and exits 0'},
    {args: ['-h'], name: '-h prints help and exits 0'},
    {args: ['help'], name: 'help prints help and exits 0'},
    {args: [], name: 'no subcommand prints help and exits 0'},
  ])('$name', async ({args}) => {
    await expect(run(args)).resolves.toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toContain('Usage: gaia-maintainer release');
    expect(stdio.errors).toHaveLength(0);
  });

  // The guard this suite exists to pin only earns its keep if dispatch still
  // works. Without this case, emptying SUBCOMMAND_HANDLERS leaves the suite
  // green while every real subcommand is dead.
  test('a known subcommand runs its handler and propagates its exit code', async () => {
    vi.mocked(runBump).mockResolvedValue(7);

    await expect(run(['bump', '--auto'])).resolves.toBe(7);
    expect(runBump).toHaveBeenCalledWith(['--auto']);
  });

  // A bare `Record` index resolves every `Object.prototype` member, so these
  // tokens would dispatch to an inherited method: the callable ones ran and
  // returned a non-number (silently exiting 0 without doing anything), and
  // `__proto__` resolved to a non-callable and crashed the router. Each must be
  // rejected as an unknown subcommand like any other typo.
  test.each<{name: string; token: string}>([
    {name: 'an unknown subcommand is rejected', token: 'bogus'},
    ...[
      'toString',
      'constructor',
      'valueOf',
      'hasOwnProperty',
      '__proto__',
    ].map((token) => ({
      name: `the Object.prototype member ${token} is not a subcommand`,
      token,
    })),
  ])('$name', async ({token}) => {
    await expect(run([token])).resolves.toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(readStderrPayload()).toMatchObject({code: 'unknown_subcommand'});
    expect(runBump).not.toHaveBeenCalled();
  });
});
