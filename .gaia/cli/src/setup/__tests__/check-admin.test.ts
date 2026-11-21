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

const describeState = (root: string): unknown => {
  const statePath = resolveStateFilePath(root);

  if (!existsSync(statePath)) {
    return 'absent';
  }
  const text = readFileSync(statePath, 'utf8');

  try {
    return {admin: (JSON.parse(text) as Record<string, unknown>).admin};
  } catch {
    return text;
  }
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

  const authStatusCall = ['auth', 'status'];
  const adminApiCall = ['api', 'repos/foo/bar', '--jq', '.permissions.admin'];

  test.each([
    {
      admin: true,
      authStatus: 'ok',
      calls: [authStatusCall, adminApiCall],
      name: 'returns admin: true, auth_status: ok when gh auth ok and api returns true',
      // First call: `gh auth status` (exits 0 with no stdout). Second
      // call: `gh api ...` returns "true\n".
      shim: {exitCode: 0, stdoutQueue: ['', 'true\n']},
    },
    {
      admin: false,
      authStatus: 'ok',
      calls: [authStatusCall, adminApiCall],
      name: 'returns admin: false, auth_status: ok when api returns false',
      shim: {exitCode: 0, stdoutQueue: ['', 'false\n']},
    },
    {
      // Critical contract: never false-positive admin.
      admin: false,
      authStatus: 'unauthenticated',
      calls: [authStatusCall],
      name: 'returns admin: false, auth_status: unauthenticated when gh auth fails',
      shim: {exitCode: 1},
    },
    {
      admin: false,
      authStatus: 'api_error',
      calls: [authStatusCall, adminApiCall],
      name: 'returns admin: false, auth_status: api_error when api call fails',
      // First gh call (auth status) succeeds; second (api) fails.
      shim: {exitCodeQueue: [0, 1], stdoutQueue: ['', '']},
    },
  ])('$name', async ({admin, authStatus, calls, shim}) => {
    const handle = sandbox.installGhShim(shim);
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.admin).toBe(admin);
    expect(parsed.auth_status).toBe(authStatus);
    expect(JSON.parse(readFileSync(sandbox.ghArgvPath, 'utf8'))).toEqual(calls);
  });

  test.each([
    {
      args: ['--repo', 'bar', '--json'],
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

  describe('caches the answer in setup-state.json', () => {
    const adminTrue = {exitCode: 0, stdoutQueue: ['', 'true\n']};
    const adminFalse = {exitCode: 0, stdoutQueue: ['', 'false\n']};
    const apiError = {exitCodeQueue: [0, 1], stdoutQueue: ['', '']};

    const prewriteState = (content: string | undefined): void => {
      if (content !== undefined) {
        mkdirSync(path.dirname(resolveStateFilePath(sandbox.root)), {
          recursive: true,
        });
        writeFileSync(resolveStateFilePath(sandbox.root), content, 'utf8');
      }
    };

    test.each([
      {
        name: 'an ok probe creates the state file and caches admin: true',
        prewrite: undefined,
        printedAdmin: true,
        probes: [adminTrue],
        state: {admin: true},
      },
      {
        name: 'an ok probe caches admin: false over an earlier true',
        prewrite: undefined,
        printedAdmin: false,
        probes: [adminTrue, adminFalse],
        state: {admin: false},
      },
      {
        name: 'an unauthenticated probe writes no state file',
        prewrite: undefined,
        printedAdmin: false,
        probes: [{exitCode: 1}],
        state: 'absent',
      },
      {
        name: 'an api error leaves the cached answer as it was',
        prewrite: undefined,
        printedAdmin: false,
        probes: [adminTrue, apiError],
        state: {admin: true},
      },
      {
        name: 'a malformed state file is left as it was and the probe still answers',
        prewrite: '{',
        printedAdmin: true,
        probes: [adminTrue],
        state: '{',
      },
    ])('$name', async ({prewrite, printedAdmin, probes, state}) => {
      prewriteState(prewrite);

      for (const shim of probes) {
        stdio.out.length = 0;
        await probe(shim);
      }

      expect(describeState(sandbox.root)).toEqual(state);
      expect(
        (JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>).admin
      ).toBe(printedAdmin);
    });
  });
});
