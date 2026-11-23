import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {run} from './index.js';

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

describe('update-deps namespace router', () => {
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    vi.restoreAllMocks();
  });

  test('no subcommand prints namespace help and exits 0', async () => {
    const exit = await run([]);
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia update-deps');
    expect(stdio.outputs.join('')).toContain('run');
  });

  test('--help prints namespace help and exits 0', async () => {
    const exit = await run(['--help']);
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia update-deps');
  });

  test('unknown subcommand reports a structured error and exits 1', async () => {
    const exit = await run(['bogus']);
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown_subcommand');
  });

  test.each(
    [
      {name: 'run --help prints subcommand usage and exits 0', verb: 'run'},
      {
        name: 'decline --help routes to the decline handler and exits 0',
        verb: 'decline',
      },
      ...[
        'advisories',
        'advisory-landed',
        'dismiss-alert',
        'write-security-cache',
        'check-security-override',
      ].map((verb) => ({
        name: `${verb} --help routes to its handler and exits 0`,
        verb,
      })),
    ].map((row) => [row.name, row] as const)
  )('%s', async (_name, {verb}) => {
    const exit = await run([verb, '--help']);
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain(`Usage: gaia update-deps ${verb}`);
  });

  test('namespace help lists the advisories and advisory-landed subcommands', async () => {
    const exit = await run([]);
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain(
      'advisories --emit <path> [--count-only] [--updates <path>]'
    );
    expect(stdio.outputs.join('')).toContain(
      'advisory-landed --package <name> --vulnerable-range <range>'
    );
  });

  test('namespace help lists every update-deps verb', async () => {
    const exit = await run([]);
    expect(exit).toBe(0);

    for (const verb of [
      'run',
      'decline',
      'global-tools',
      'advisories',
      'advisory-landed',
      'dismiss-alert',
      'write-security-cache',
      'check-security-override',
    ]) {
      expect(stdio.outputs.join('')).toContain(`  ${verb} `);
    }
  });
});
