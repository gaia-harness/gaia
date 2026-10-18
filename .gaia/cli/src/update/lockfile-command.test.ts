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
  writeTree('frontend/package.json', packageJson());
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

describe('update lockfile-command', () => {
  test('no change prints none', () => {
    expect(run(['--root', root])).toBe(0);
    expect(outputs.join('')).toBe('none\n');
  });

  test('an overrides change alone prints dedupe', () => {
    writeTree(
      'pnpm-workspace.yaml',
      'minimumReleaseAge: 1440\noverrides:\n  qs: ">=6.5.0"\n'
    );

    expect(lockfileCommand(root, 'HEAD')).toBe('dedupe');
  });

  test.each([
    ['allowBuilds', 'allowBuilds:\n  msw: true\n'],
    ['resolutionMode', 'resolutionMode: highest\n'],
    ['dedupePeerDependents', 'dedupePeerDependents: false\n'],
    ['autoInstallPeers', 'autoInstallPeers: false\n'],
    ['kebab-case dedupe-peer-dependents', 'dedupe-peer-dependents: false\n'],
  ])('a %s change prints dedupe', (_name, addition) => {
    writeTree('pnpm-workspace.yaml', `${BASELINE_WORKSPACE}${addition}`);

    expect(lockfileCommand(root, 'HEAD')).toBe('dedupe');
  });

  test('an overrides change plus a dependency change prints dedupe', () => {
    writeTree(
      'pnpm-workspace.yaml',
      'minimumReleaseAge: 1440\noverrides:\n  qs: ">=6.5.0"\n'
    );
    writeTree('package.json', packageJson({dependencies: {react: '^19.1.0'}}));

    expect(lockfileCommand(root, 'HEAD')).toBe('dedupe');
  });

  test('a dependency version change alone prints install', () => {
    writeTree(
      'frontend/package.json',
      packageJson({dependencies: {react: '^19.1.0'}})
    );

    expect(lockfileCommand(root, 'HEAD')).toBe('install');
  });

  test('a packageManager change alone prints install', () => {
    writeTree('package.json', packageJson({packageManager: 'pnpm@11.3.0'}));

    expect(lockfileCommand(root, 'HEAD')).toBe('install');
  });

  test('a change confined to a non-trigger key prints none', () => {
    writeTree(
      'pnpm-workspace.yaml',
      BASELINE_WORKSPACE.replace('1440', '4320')
    );
    writeTree('package.json', packageJson({scripts: {build: 'vite build'}}));

    expect(lockfileCommand(root, 'HEAD')).toBe('none');
  });

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
    writeTree(
      '.gaia/packages.json',
      JSON.stringify([{name: 'evil', path: '../outside'}])
    );
    commit();

    expect(lockfileCommand(root, 'HEAD')).toBe('none');
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

  test('an unreadable ref exits non-zero with a structured error', () => {
    expect(run(['--root', root, '--ref', 'no-such-ref'])).not.toBe(0);
    expect(errors.join('')).toContain('ref_unreadable');
  });

  test('a malformed working-tree manifest exits non-zero with a structured error', () => {
    writeTree('package.json', '{ not json');

    expect(run(['--root', root])).not.toBe(0);
    expect(errors.join('')).toContain('parse_failed');
  });

  test('a missing --root exits non-zero', () => {
    expect(run([])).not.toBe(0);
    expect(errors.join('')).toContain('invalid_arguments');
  });
});
