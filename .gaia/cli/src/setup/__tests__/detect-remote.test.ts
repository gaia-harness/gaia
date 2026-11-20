import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {run} from '../detect-remote.js';
import {setupSandbox} from './sandbox.js';
import type {Sandbox} from './sandbox.js';

const captureStdio = (): {
  err: string[];
  out: string[];
  restore: () => void;
} => {
  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      err.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    err,
    out,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

describe('setup detect-remote', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-detect-remote-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('returns parsed fields when origin is configured', () => {
    execFileSync(
      'git',
      ['remote', 'add', 'origin', 'git@github.com:foo/bar.git'],
      {cwd: sandbox.root}
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toBe(true);
    expect(parsed.host).toBe('github.com');
    expect(parsed.owner).toBe('foo');
    expect(parsed.repo).toBe('bar');
  });

  const addOrigin = (remote: string | undefined): void => {
    if (remote !== undefined) {
      execFileSync('git', ['remote', 'add', 'origin', remote], {
        cwd: sandbox.root,
      });
    }
  };

  test.each([
    {
      name: 'returns found: false when origin is missing',
      remote: undefined,
      url: null,
    },
    {
      name: 'returns found: false when remote URL is unparseable',
      remote: 'https://gitlab.com/foo/bar/baz.git',
      // The URL itself is preserved for diagnostics.
      url: 'https://gitlab.com/foo/bar/baz.git',
    },
  ])('$name', ({remote, url}) => {
    addOrigin(remote);

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toBe(false);
    expect(parsed.url).toBe(url);
    expect(parsed.host).toBeNull();
  });

  test('emits a human report without --json', () => {
    execFileSync(
      'git',
      ['remote', 'add', 'origin', 'https://github.com/foo/bar'],
      {cwd: sandbox.root}
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('host: github.com');
  });

  test.each([
    {
      args: ['--bogus'],
      name: 'rejects unknown flags',
      stream: 'err',
      succeeds: false,
      text: 'unknown flag',
    },
    {
      args: ['--help'],
      name: '--help exits 0',
      stream: 'out',
      succeeds: true,
      text: 'Usage:',
    },
  ] as const)('$name', ({args, stream, succeeds, text}) => {
    const exit = run([...args], {cwd: sandbox.root});

    expect(exit === 0).toBe(succeeds);
    expect(stdio[stream].join('')).toContain(text);
  });
});
