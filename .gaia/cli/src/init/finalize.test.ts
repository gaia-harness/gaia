import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './finalize.js';
import {
  markStepCompleted,
  readState,
  stateFilePath,
  STEP_ORDER,
} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-finalize-'));
  mkdirSync(path.join(root, '.claude', 'commands'), {recursive: true});
  writeFileSync(
    path.join(root, '.claude', 'commands', 'gaia-init.md'),
    '# gaia-init\n',
    'utf8'
  );

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

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

describe('init finalize CLI', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('deletes the command file, records state', async () => {
    sandbox = setupSandbox();

    const exit = await run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');

    expect(
      existsSync(path.join(sandbox.root, '.claude', 'commands', 'gaia-init.md'))
    ).toBe(false);

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('finalize');
  });

  test('deletes the state file once every earlier step is complete', async () => {
    sandbox = setupSandbox();

    for (const step of STEP_ORDER.filter((name) => name !== 'finalize')) {
      markStepCompleted(sandbox.root, step);
    }

    const exit = await run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(existsSync(stateFilePath(sandbox.root))).toBe(false);
  });

  test('keeps the state file while an earlier step is incomplete', async () => {
    sandbox = setupSandbox();
    markStepCompleted(sandbox.root, 'strip-branding');

    const exit = await run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const state = readState(sandbox.root);
    expect(state.completed_steps).toEqual(['strip-branding', 'finalize']);
  });

  test('idempotent: re-running is safe', async () => {
    sandbox = setupSandbox();
    await run([], {cwd: sandbox.root});
    const second = await run([], {cwd: sandbox.root});
    expect(second).toBe(0);
  });

  test('rejects unknown flags', async () => {
    sandbox = setupSandbox();
    const exit = await run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });
});
