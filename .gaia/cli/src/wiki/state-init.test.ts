import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './state-init.js';

type Sandbox = {
  cleanup: () => void;
  headSha: string;
  root: string;
  statePath: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-state-init-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  // Need at least one commit so HEAD resolves.
  writeFileSync(path.join(root, 'README.md'), '# test\n', 'utf8');
  execFileSync('git', ['add', 'README.md'], {cwd: root});
  execFileSync('git', ['commit', '-q', '-m', 'initial'], {cwd: root});
  const headSha = execFileSync('git', ['rev-parse', 'HEAD'], {
    cwd: root,
    encoding: 'utf8',
  }).trim();

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    headSha,
    root,
    statePath: path.join(root, 'wiki', '.state.json'),
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

describe('wiki state-init', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('creates wiki/.state.json with the expected shape', () => {
    const fixedNow = new Date('2026-05-07T12:00:00.000Z');
    const exit = run([sandbox.headSha], {
      cwd: sandbox.root,
      now: () => fixedNow,
    });
    expect(exit).toBe(0);

    expect(existsSync(sandbox.statePath)).toBe(true);
    const written = readFileSync(sandbox.statePath, 'utf8');
    const parsed = JSON.parse(written) as Record<string, unknown>;
    expect(parsed).toEqual({
      last_evaluated_at: '2026-05-07T12:00:00.000Z',
      last_evaluated_sha: sandbox.headSha,
      version: 1,
    });
    // Pretty-printed with 2 spaces and trailing newline.
    expect(written.endsWith('\n')).toBe(true);
    expect(written).toContain('  "version": 1');
  });

  test('resolves short shas, branches, and HEAD', () => {
    const exit = run(['HEAD'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const parsed = JSON.parse(
      readFileSync(sandbox.statePath, 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.last_evaluated_sha).toBe(sandbox.headSha);
  });

  test('creates the wiki directory if missing', () => {
    expect(existsSync(path.join(sandbox.root, 'wiki'))).toBe(false);
    const exit = run([sandbox.headSha], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(existsSync(path.join(sandbox.root, 'wiki'))).toBe(true);
  });

  test('refuses when wiki/.state.json already exists', () => {
    mkdirSync(path.join(sandbox.root, 'wiki'), {recursive: true});
    writeFileSync(sandbox.statePath, '{"version":1}\n', 'utf8');

    const exit = run([sandbox.headSha], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('state_already_exists');
    // Existing file untouched.
    expect(readFileSync(sandbox.statePath, 'utf8')).toBe('{"version":1}\n');
  });

  const stateInitRefusalsCases: readonly {
    args: (headSha: string) => string[];
    message: string;
    name: string;
    stream: 'errors' | 'outputs';
  }[] = [
    {
      args: () => ['nonexistent-ref'],
      message: 'sha_unresolvable',
      name: 'refuses when <sha> cannot be resolved',
      stream: 'errors',
    },
    {
      args: () => [],
      message: 'Usage:',
      name: 'exits 1 with usage hint when no args supplied',
      stream: 'outputs',
    },
    {
      args: (headSha) => [headSha, 'extra'],
      message: 'exactly',
      name: 'exits 1 when extra positional args are supplied',
      stream: 'errors',
    },
    {
      args: () => ['--bogus'],
      message: 'unknown flag',
      name: 'exits 1 when an unknown flag is supplied',
      stream: 'errors',
    },
  ];

  test.each(stateInitRefusalsCases.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {args, message, stream}) => {
      const exit = run(args(sandbox.headSha), {cwd: sandbox.root});
      expect(exit).toBe(1);
      expect(stdio[stream].join('')).toContain(message);
      expect(existsSync(sandbox.statePath)).toBe(false);
    }
  );

  test('--help exits 0 and prints usage', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage:');
  });
});
