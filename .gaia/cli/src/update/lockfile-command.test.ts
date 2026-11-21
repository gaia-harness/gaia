/**
 * Strategy: build a temporary repository, commit a baseline of the manifests,
 * change the working tree, and assert which pnpm command the handler prints.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {lockfileCommand, run} from './lockfile-command.js';

let root = '';
let outputs: string[] = [];
let errors: string[] = [];

const runGit = (...args: string[]): void => {
  execFileSync(
    'git',
    [
      '-C',
      root,
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ],
    {stdio: 'ignore'}
  );
};

const writeTree = (relativePath: string, contents: string): void => {
  const absolute = path.join(root, relativePath);
  mkdirSync(path.dirname(absolute), {recursive: true});
  writeFileSync(absolute, contents, 'utf8');
};

const packageJson = (fields: Record<string, unknown> = {}): string =>
  JSON.stringify({
    dependencies: {react: '^19.0.0'},
    name: 'app',
    ...fields,
  });

const BASELINE_WORKSPACE =
  'minimumReleaseAge: 1440\noverrides:\n  qs: ">=6.0.0"\n';

const commit = (): void => {
  runGit('add', '-A');
  runGit('commit', '-m', 'baseline');
};

beforeEach(() => {
  root = mkdtempSync(path.join(tmpdir(), 'gaia-field-merge-lockfile-'));
  outputs = [];
  errors = [];
  runGit('init', '--quiet');
  writeTree('pnpm-workspace.yaml', BASELINE_WORKSPACE);
  writeTree('package.json', packageJson());
  writeTree('apps/web/package.json', packageJson());
  commit();
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    outputs.push(String(chunk));

    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
    errors.push(String(chunk));

    return true;
  });
});

afterEach(() => {
  vi.restoreAllMocks();
  rmSync(root, {force: true, recursive: true});
});

const OVERRIDES_CHANGED =
  'minimumReleaseAge: 1440\noverrides:\n  qs: ">=6.5.0"\n';

const DEDUPE_TRIGGER_ADDITIONS = [
  ['allowBuilds', 'allowBuilds:\n  msw: true\n'],
  ['resolutionMode', 'resolutionMode: highest\n'],
  ['dedupePeerDependents', 'dedupePeerDependents: false\n'],
  ['autoInstallPeers', 'autoInstallPeers: false\n'],
  ['kebab-case dedupe-peer-dependents', 'dedupe-peer-dependents: false\n'],
] as const;

const CHANGED_KEY_ROWS: {
  command: 'dedupe' | 'install' | 'none';
  name: string;
  writes: [string, string][];
}[] = [
  {command: 'none', name: 'no change prints none', writes: []},
  {
    command: 'dedupe',
    name: 'an overrides change alone prints dedupe',
    writes: [['pnpm-workspace.yaml', OVERRIDES_CHANGED]],
  },
  ...DEDUPE_TRIGGER_ADDITIONS.map(([key, addition]) => ({
    command: 'dedupe' as const,
    name: `a ${key} change prints dedupe`,
    writes: [['pnpm-workspace.yaml', `${BASELINE_WORKSPACE}${addition}`]] as [
      string,
      string,
    ][],
  })),
  {
    command: 'dedupe',
    name: 'an overrides change plus a dependency change prints dedupe',
    writes: [
      ['pnpm-workspace.yaml', OVERRIDES_CHANGED],
      ['package.json', packageJson({dependencies: {react: '^19.1.0'}})],
    ],
  },
  {
    command: 'install',
    name: 'a dependency version change alone prints install',
    writes: [
      [
        'apps/web/package.json',
        packageJson({dependencies: {react: '^19.1.0'}}),
      ],
    ],
  },
  {
    command: 'install',
    name: 'a packageManager change alone prints install',
    writes: [['package.json', packageJson({packageManager: 'pnpm@11.3.0'})]],
  },
  {
    command: 'none',
    name: 'a change confined to a non-trigger key prints none',
    writes: [
      ['pnpm-workspace.yaml', BASELINE_WORKSPACE.replace('1440', '4320')],
      ['package.json', packageJson({scripts: {build: 'vite build'}})],
    ],
  },
];

const REFUSAL_ROWS: {
  arguments: () => string[];
  code: string;
  name: string;
  writes: [string, string][];
}[] = [
  {
    arguments: () => ['--root', root, '--ref', 'no-such-ref'],
    code: 'ref_unreadable',
    name: 'an unreadable ref exits non-zero with a structured error',
    writes: [],
  },
  {
    arguments: () => ['--root', root],
    code: 'parse_failed',
    name: 'a malformed working-tree manifest exits non-zero with a structured error',
    writes: [['package.json', '{ not json']],
  },
  {
    arguments: () => [],
    code: 'invalid_arguments',
    name: 'a missing --root exits non-zero',
    writes: [],
  },
];

describe('update lockfile-command', () => {
  test.each(CHANGED_KEY_ROWS.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {command, writes}) => {
      for (const [file, contents] of writes) {
        writeTree(file, contents);
      }

      expect(lockfileCommand(root, 'HEAD')).toBe(command);
      expect(run(['--root', root])).toBe(0);
      expect(outputs.join('')).toBe(`${command}\n`);
    }
  );

  test('a registered package is compared too', () => {
    writeTree(
      '.gaia/packages.json',
      JSON.stringify([{name: 'web', path: 'web'}])
    );
    writeTree('web/package.json', packageJson());
    commit();
    writeTree(
      'web/package.json',
      packageJson({dependencies: {react: '^20.0.0'}})
    );

    expect(lockfileCommand(root, 'HEAD')).toBe('install');
  });

  test('a registry path outside the tree is ignored', () => {
    const siblingName = `${path.basename(root)}-outside`;
    const sibling = path.join(path.dirname(root), siblingName);

    mkdirSync(sibling);
    writeFileSync(path.join(sibling, 'package.json'), packageJson(), 'utf8');
    writeTree(
      '.gaia/packages.json',
      JSON.stringify([{name: 'evil', path: `../${siblingName}`}])
    );
    commit();

    try {
      expect(lockfileCommand(root, 'HEAD')).toBe('none');
    } finally {
      rmSync(sibling, {force: true, recursive: true});
    }
  });

  test('a file absent at the ref reads as empty', () => {
    writeTree('web/package.json', packageJson());
    writeTree(
      '.gaia/packages.json',
      JSON.stringify([{name: 'web', path: 'web'}])
    );

    expect(lockfileCommand(root, 'HEAD')).toBe('install');
  });

  test('prints a JSON object with --json', () => {
    expect(run(['--root', root, '--json'])).toBe(0);
    expect(JSON.parse(outputs.join(''))).toEqual({command: 'none'});
  });

  test.each(REFUSAL_ROWS.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {arguments: argv, code, writes}) => {
      for (const [file, contents] of writes) {
        writeTree(file, contents);
      }

      expect(run(argv())).not.toBe(0);
      expect(errors.join('')).toContain(code);
    }
  );
});
