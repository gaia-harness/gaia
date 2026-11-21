import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {run} from '../warn-existing-tools.js';
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

const NPM_CONFIG =
  'version: 2\nupdates:\n  - package-ecosystem: npm\n    directory: /\n';

const ACTIONS_CONFIG =
  'version: 2\nupdates:\n  - package-ecosystem: github-actions\n    directory: /\n';

const readOutput = (stdio: {out: string[]}): Record<string, unknown> =>
  JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;

const writeFileAt = (root: string, relPath: string, content: string): void => {
  const target = path.join(root, relPath);
  mkdirSync(path.dirname(target), {recursive: true});
  writeFileSync(target, content, 'utf8');
};

describe('setup warn-existing-tools', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-warn-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('returns empty array on a clean repo', () => {
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toEqual([]);
  });

  test.each<[string, string, string, string[]]>([
    [
      'detects .github/dependabot.yml',
      '.github/dependabot.yml',
      NPM_CONFIG,
      ['dependabot'],
    ],
    [
      'detects .github/dependabot.yaml',
      '.github/dependabot.yaml',
      NPM_CONFIG,
      ['dependabot'],
    ],
    ['detects renovate.json', 'renovate.json', '{}\n', ['renovate']],
  ])('%s', (_label, file, contents, found) => {
    writeFileAt(sandbox.root, file, contents);

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toEqual(found);
  });

  test.each<[string, [string, string][], string[]]>([
    [
      'detects .renovaterc.json and .github/renovate.json under same name',
      [
        ['.renovaterc.json', '{}\n'],
        ['.github/renovate.json', '{}\n'],
      ],
      ['renovate'],
    ],
    [
      'reports both when both exist',
      [
        ['.github/dependabot.yml', NPM_CONFIG],
        ['renovate.json', '{}\n'],
      ],
      ['dependabot', 'renovate'],
    ],
    [
      'deduplicates when both .yml and .yaml exist',
      [
        ['.github/dependabot.yml', NPM_CONFIG],
        ['.github/dependabot.yaml', NPM_CONFIG],
      ],
      ['dependabot'],
    ],
  ])('%s', (_name, files, found) => {
    for (const [file, contents] of files) {
      writeFileAt(sandbox.root, file, contents);
    }

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    expect(readOutput(stdio).found).toEqual(found);
  });

  test.each(
    [
      {
        contents: ACTIONS_CONFIG,
        found: [],
        isUnparseable: false,
        name: 'a config with only non-npm entries reports nothing',
      },
      {
        contents: 'version: 2\n',
        found: [],
        isUnparseable: false,
        name: 'a config with no updates list reports nothing',
      },
      {
        contents: `${ACTIONS_CONFIG}  - package-ecosystem: npm\n    directory: /\n`,
        found: ['dependabot'],
        isUnparseable: false,
        name: 'an npm entry among other ecosystems reports dependabot',
      },
      {
        contents: 'updates: [unclosed\n',
        found: ['dependabot'],
        isUnparseable: true,
        name: 'an unparseable config reports dependabot and flags it unparseable',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {contents, found, isUnparseable}) => {
    writeFileAt(sandbox.root, '.github/dependabot.yml', contents);

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    expect(readOutput(stdio)).toEqual({
      dependabot_unparseable: isUnparseable,
      found,
    });
  });

  test('emits a human report without --json', () => {
    writeFileAt(sandbox.root, '.github/dependabot.yml', NPM_CONFIG);

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('detected: dependabot');
  });

  test('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown flag');
  });

  test('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
