import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {run} from '../check-admin.js';
import {resolveStateFilePath} from '../util/state-file.js';
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

type GhShim = Parameters<Sandbox['installGhShim']>[0];

const readCachedAdmin = (root: string): unknown =>
  (
    JSON.parse(readFileSync(resolveStateFilePath(root), 'utf8')) as Record<
      string,
      unknown
    >
  ).admin;

/** Run one probe against a fresh gh shim; returns the shim's restore. */
const probeWithShim = async (
  sandbox: Sandbox,
  shim: GhShim
): Promise<() => void> => {
  const handle = sandbox.installGhShim(shim);
  await run(['--owner', 'foo', '--repo', 'bar', '--json'], {
    cwd: sandbox.root,
  });

  return handle.restore;
};

describe('setup check-admin', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let restore: (() => void) | undefined;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-check-admin-');
    stdio = captureStdio();
  });

  afterEach(() => {
    restore?.();
    restore = undefined;
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  const probe = async (shim: GhShim): Promise<void> => {
    restore?.();
    restore = await probeWithShim(sandbox, shim);
  };

  test('returns admin: true, auth_status: ok when gh auth ok and api returns true', async () => {
    // First call: `gh auth status` (exits 0 with no stdout). Second
    // call: `gh api ...` returns "true\n".
    const handle = sandbox.installGhShim({
      exitCode: 0,
      stdoutQueue: ['', 'true\n'],
    });
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.admin).toBe(true);
    expect(parsed.auth_status).toBe('ok');

    const recorded = JSON.parse(
      readFileSync(sandbox.ghArgvPath, 'utf8')
    ) as string[][];
    expect(recorded[0]).toEqual(['auth', 'status']);
    expect(recorded[1]).toEqual([
      'api',
      'repos/foo/bar',
      '--jq',
      '.permissions.admin',
    ]);
  });

  test('returns admin: false, auth_status: ok when api returns false', async () => {
    const handle = sandbox.installGhShim({
      exitCode: 0,
      stdoutQueue: ['', 'false\n'],
    });
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.admin).toBe(false);
    expect(parsed.auth_status).toBe('ok');
  });

  test('returns admin: false, auth_status: unauthenticated when gh auth fails', async () => {
    // gh auth status fails -> exit code != 0.
    const handle = sandbox.installGhShim({exitCode: 1});
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    // Critical contract: never false-positive admin.
    expect(parsed.admin).toBe(false);
    expect(parsed.auth_status).toBe('unauthenticated');
  });

  test('returns admin: false, auth_status: api_error when api call fails', async () => {
    // First gh call (auth status) succeeds; second (api) fails.
    const handle = sandbox.installGhShim({
      exitCodeQueue: [0, 1],
      stdoutQueue: ['', ''],
    });
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.admin).toBe(false);
    expect(parsed.auth_status).toBe('api_error');
  });

  test('exits non-zero when --owner missing', async () => {
    const exit = await run(['--repo', 'bar', '--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('missing_required_arg');
  });

  test('rejects unknown flags', async () => {
    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--bogus'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown flag');
  });

  test('--help exits 0', async () => {
    const exit = await run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });

  describe('caches the answer in setup-state.json', () => {
    test('an ok probe creates the state file and caches admin: true', async () => {
      await probe({exitCode: 0, stdoutQueue: ['', 'true\n']});
      expect(readCachedAdmin(sandbox.root)).toBe(true);
    });

    test('an ok probe caches admin: false over an earlier true', async () => {
      await probe({exitCode: 0, stdoutQueue: ['', 'true\n']});
      await probe({exitCode: 0, stdoutQueue: ['', 'false\n']});
      expect(readCachedAdmin(sandbox.root)).toBe(false);
    });

    test('an unauthenticated probe writes no state file', async () => {
      await probe({exitCode: 1});
      expect(existsSync(resolveStateFilePath(sandbox.root))).toBe(false);
    });

    test('an api error leaves the cached answer as it was', async () => {
      await probe({exitCode: 0, stdoutQueue: ['', 'true\n']});
      await probe({exitCodeQueue: [0, 1], stdoutQueue: ['', '']});
      expect(readCachedAdmin(sandbox.root)).toBe(true);
    });

    test('a malformed state file is left as it was and the probe still answers', async () => {
      mkdirSync(path.dirname(resolveStateFilePath(sandbox.root)), {
        recursive: true,
      });
      writeFileSync(resolveStateFilePath(sandbox.root), '{', 'utf8');
      await probe({exitCode: 0, stdoutQueue: ['', 'true\n']});
      expect(readFileSync(resolveStateFilePath(sandbox.root), 'utf8')).toBe(
        '{'
      );
      expect(
        (JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>).admin
      ).toBe(true);
    });
  });
});
