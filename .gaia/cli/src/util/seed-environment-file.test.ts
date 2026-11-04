import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import type * as NodeFs from 'node:fs';
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {writeBuiltinDescriptor} from './package-fixture.js';
import {seedEnvironmentFile, UNEXPECTED_EXIT} from './seed-environment-file.js';

const fsSpies = vi.hoisted(() => ({
  actualExistsSync: undefined as
    ((candidate: NodeFs.PathLike) => boolean) | undefined,
  existsSync: vi.fn(),
}));

vi.mock('node:fs', async (importOriginal) => {
  const actual = await importOriginal<typeof NodeFs>();

  fsSpies.actualExistsSync = actual.existsSync;

  return {...actual, existsSync: fsSpies.existsSync};
});

let root: string;
let errors: string[];

beforeEach(() => {
  fsSpies.existsSync.mockImplementation((candidate: NodeFs.PathLike) =>
    fsSpies.actualExistsSync!(candidate)
  );
  root = mkdtempSync(path.join(tmpdir(), 'gaia-seed-environment-file-'));
  writeBuiltinDescriptor(root);
  errors = [];
  vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
    errors.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  });
});

afterEach(() => {
  chmodSync(path.join(root, 'apps', 'web'), 0o755);
  vi.restoreAllMocks();
  rmSync(root, {force: true, recursive: true});
});

const webFile = (name: string): string => path.join(root, 'apps', 'web', name);

describe('seedEnvironmentFile', () => {
  test('creates .env from the example on the first run', () => {
    writeFileSync(webFile('.env.example'), 'FOO=bar\n', 'utf8');

    expect(seedEnvironmentFile(root, 'test')).toBe(EXIT_CODES.OK);
    expect(readFileSync(webFile('.env'), 'utf8')).toBe('FOO=bar\n');
  });

  // The OS sandbox's denyRead also denies stat, so an existence check reports
  // a present .env as absent; only an exclusive create keeps it intact.
  test('never overwrites a present .env, even when an existence check cannot see it', () => {
    writeFileSync(webFile('.env'), 'EXISTING=1\n', 'utf8');
    writeFileSync(webFile('.env.example'), 'FOO=bar\n', 'utf8');
    fsSpies.existsSync.mockImplementation(
      (candidate: NodeFs.PathLike) =>
        String(candidate) !== webFile('.env') &&
        fsSpies.actualExistsSync!(candidate)
    );

    expect(seedEnvironmentFile(root, 'test')).toBe(EXIT_CODES.OK);
    expect(readFileSync(webFile('.env'), 'utf8')).toBe('EXISTING=1\n');
    expect(errors).toEqual([]);
  });

  test('fails with the structured error on any other write failure', () => {
    writeFileSync(webFile('.env.example'), 'FOO=bar\n', 'utf8');
    chmodSync(path.join(root, 'apps', 'web'), 0o555);

    expect(seedEnvironmentFile(root, 'test')).toBe(UNEXPECTED_EXIT);
    expect(errors.join('')).toContain('bootstrap_env_failed');
  });
});
