import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './near-collisions.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writePage: (relativePath: string, contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-collisions-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    writePage: (relativePath, contents) => {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    },
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

describe('wiki near-collisions', () => {
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

  test('flags slug pairs within max-distance per domain', () => {
    sandbox.writePage('wiki/concepts/auth-flow.md', '# Auth\n');
    sandbox.writePage('wiki/concepts/auth-flows.md', '# Auths\n');
    sandbox.writePage('wiki/concepts/Routing.md', '# Routing\n');
    sandbox.writePage('wiki/decisions/oauth.md', '# OAuth\n');
    sandbox.writePage('wiki/decisions/oauth2.md', '# OAuth2\n');

    const exit = run(['--max-distance', '2'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const out = stdio.outputs.join('').trim();
    const rows = out.split('\n').map((line) => line.split('\t'));
    expect(rows).toContainEqual(['concepts', 'auth-flow', 'auth-flows', '1']);
    expect(rows).toContainEqual(['decisions', 'oauth', 'oauth2', '1']);

    // Routing should NOT collide with anything.
    for (const row of rows) {
      expect(row).not.toContain('Routing');
    }
  });

  const maxDistanceThresholdCases: readonly {
    args: readonly string[];
    name: string;
    output: string;
    pages: readonly string[];
  }[] = [
    {
      args: ['--max-distance', '2'],
      name: 'respects --max-distance threshold',
      // Distance between "short" and "somewhat-longer" >> 2.
      output: '',
      pages: ['wiki/concepts/short.md', 'wiki/concepts/somewhat-longer.md'],
    },
    {
      args: [],
      name: 'default --max-distance is 3',
      output: 'concepts\tabcd\tabcde\t1',
      pages: ['wiki/concepts/abcd.md', 'wiki/concepts/abcde.md'],
    },
  ];

  test.each(maxDistanceThresholdCases.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {args, output, pages}) => {
      for (const page of pages) {
        sandbox.writePage(page, '# Page\n');
      }

      const exit = run([...args], {cwd: sandbox.root});
      expect(exit).toBe(0);
      expect(stdio.outputs.join('').trim()).toBe(output);
    }
  );

  test('normalizes _ and - so they do not contribute to the distance', () => {
    sandbox.writePage('wiki/concepts/a-b.md', '# A\n');
    sandbox.writePage('wiki/concepts/a_b.md', '# B\n');

    const exit = run(['--max-distance', '1'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const out = stdio.outputs.join('').trim();
    expect(out).toContain('concepts\ta-b\ta_b\t0');
  });

  const nearCollisionsRefusalsCases: readonly {
    args: readonly string[];
    error: string;
    name: string;
  }[] = [
    {
      args: ['--max-distance', 'no'],
      error: 'positive integer',
      name: 'rejects malformed --max-distance',
    },
    {
      args: ['--bogus'],
      error: 'unknown flag',
      name: 'rejects unknown flag',
    },
  ];

  test.each(nearCollisionsRefusalsCases.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {args, error}) => {
      const exit = run([...args], {cwd: sandbox.root});
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain(error);
    }
  );
});
