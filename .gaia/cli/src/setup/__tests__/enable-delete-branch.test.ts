import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {readFileSync} from 'node:fs';
import {run} from '../enable-delete-branch.js';
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

describe('setup enable-delete-branch', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let restore: (() => void) | undefined;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-enable-delete-branch-');
    stdio = captureStdio();
  });

  afterEach(() => {
    restore?.();
    restore = undefined;
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test.each([
    {
      applied: true,
      error: undefined,
      name: 'PATCHes delete_branch_on_merge=true on success',
      ok: true,
      shim: {exitCode: 0},
    },
    {
      applied: false,
      error: 'gh_api_error',
      name: 'returns applied: false with error on gh failure',
      ok: false,
      shim: {exitCode: 1},
    },
  ])('$name', async ({applied, error, ok, shim}) => {
    const handle = sandbox.installGhShim(shim);
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar'], {
      cwd: sandbox.root,
    });
    expect(exit === 0).toBe(ok);

    const recorded = JSON.parse(
      readFileSync(sandbox.ghArgvPath, 'utf8')
    ) as string[][];
    expect(recorded[0]).toEqual([
      'api',
      '-X',
      'PATCH',
      'repos/foo/bar',
      '-f',
      'delete_branch_on_merge=true',
    ]);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.applied).toBe(applied);
    expect(parsed.error).toBe(error);
  });

  test.each([
    {
      args: ['--repo', 'bar'],
      name: 'exits non-zero when --owner missing',
      stream: 'err',
      succeeds: false,
      text: 'missing_required_arg',
    },
    {
      args: ['--owner', 'foo', '--repo', 'bar', '--bogus'],
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
  ] as const)('$name', async ({args, stream, succeeds, text}) => {
    const exit = await run([...args], {cwd: sandbox.root});

    expect(exit === 0).toBe(succeeds);
    expect(stdio[stream].join('')).toContain(text);
  });
});
