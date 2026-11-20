import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './log-prepend.js';

const SAMPLE_LOG = `---
type: meta
title: Log
status: active
---

# Log

## [Unreleased]

- 2026-01-01 abc1234 - WORTHY: existing entry
`;

type Sandbox = {
  cleanup: () => void;
  logPath: string;
  root: string;
};

const setupSandbox = (logBody: string): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-log-prepend-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});
  const logPath = path.join(root, 'wiki', 'log.md');
  writeFileSync(logPath, logBody, 'utf8');

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    logPath,
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

describe('wiki log-prepend', () => {
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

  const logPrependWritesEachDecisionCases: readonly {
    args: readonly string[];
    entry: string;
    name: string;
  }[] = [
    {
      args: ['--sha', 'def5678', '--decision', 'SKIP', '--reason', 'test'],
      entry: '- 2026-05-07 def5678 SKIP - test',
      name: 'prepends a SKIP entry under [Unreleased]',
    },
    {
      args: [
        '--sha',
        '0123456',
        '--decision',
        'WORTHY',
        '--reason',
        'added module',
      ],
      entry: '- 2026-05-07 0123456 WORTHY - added module',
      name: 'prepends a WORTHY entry',
    },
    {
      args: [
        '--sha',
        'feedbac',
        '--decision',
        'RE_ANCHOR',
        '--reason',
        're-anchored after history rewrite',
      ],
      entry:
        '- 2026-05-07 feedbac RE_ANCHOR - re-anchored after history rewrite',
      name: 'prepends a RE_ANCHOR entry',
    },
  ];

  test.each(
    logPrependWritesEachDecisionCases.map((row) => [row.name, row] as const)
  )('%s', (_name, {args, entry}) => {
    sandbox = setupSandbox(SAMPLE_LOG);

    const exit = run([...args], {cwd: sandbox.root, today: '2026-05-07'});
    expect(exit).toBe(0);

    const written = readFileSync(sandbox.logPath, 'utf8');
    expect(written).toContain(entry);
    // The new entry should appear before the existing entry.
    expect(written.indexOf(entry)).toBeLessThan(written.indexOf('abc1234'));
  });

  const logPrependRefusalsCases: readonly {
    args: readonly string[];
    errors: readonly string[];
    logBody: string;
    name: string;
  }[] = [
    {
      args: ['--sha', 'def5678', '--decision', 'MAYBE', '--reason', 'oops'],
      errors: ['--decision must be', 'RE_ANCHOR'],
      logBody: SAMPLE_LOG,
      name: 'rejects invalid --decision',
    },
    {
      args: ['--decision', 'SKIP', '--reason', 'r'],
      errors: ['--sha is required'],
      logBody: SAMPLE_LOG,
      name: 'rejects missing --sha',
    },
    ...['constructor', 'toString', 'valueOf', '__proto__'].map((token) => ({
      args: [token, 'swallowed'],
      errors: [`unknown flag: ${token}`],
      logBody: SAMPLE_LOG,
      name: `rejects a flag named after an Object.prototype key (${token})`,
    })),
    {
      args: ['--sha', 'abc', '--decision', 'SKIP'],
      errors: ['--reason is required'],
      logBody: SAMPLE_LOG,
      name: 'rejects missing --reason',
    },
    {
      args: ['--sha', 'abc', '--decision', 'SKIP', '--reason', 'r'],
      errors: ['frontmatter'],
      logBody: '# Log\n\nno frontmatter\n',
      name: 'exits 1 when frontmatter fence is missing',
    },
    {
      args: ['--sha', 'abc', '--decision', 'SKIP', '--reason', 'r'],
      errors: ['frontmatter'],
      logBody: '---\ntype: meta\n\n# Log\n',
      name: 'exits 1 when frontmatter is unterminated',
    },
  ];

  test.each(logPrependRefusalsCases.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {args, errors, logBody}) => {
      sandbox = setupSandbox(logBody);

      const exit = run([...args], {cwd: sandbox.root});

      expect(exit).toBe(1);

      for (const error of errors) {
        expect(stdio.errors.join('')).toContain(error);
      }
    }
  );

  test('inserts after closing fence when no H2 heading exists', () => {
    const minimal = '---\ntype: meta\n---\n\n# Log\n';
    sandbox = setupSandbox(minimal);

    const exit = run(
      ['--sha', 'def5678', '--decision', 'SKIP', '--reason', 'flat'],
      {cwd: sandbox.root, today: '2026-05-07'}
    );
    expect(exit).toBe(0);

    const written = readFileSync(sandbox.logPath, 'utf8');
    expect(written).toContain('- 2026-05-07 def5678 SKIP - flat');
  });
});
