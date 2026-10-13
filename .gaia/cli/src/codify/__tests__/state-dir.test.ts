import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync, spawnSync} from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import * as runProcess from '../../util/run-process.js';
import {relocateCodifyState} from '../state-dir.js';
import {run as runTally} from '../tally.js';

const CLI_ROOT = path.resolve(import.meta.dirname, '..', '..', '..');
const TSX_BINARY = path.join(CLI_ROOT, 'node_modules', '.bin', 'tsx');
const CLI_ENTRY = path.join(CLI_ROOT, 'src', 'index.ts');

const git = (cwd: string, ...args: string[]): void => {
  execFileSync(
    'git',
    [
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.invalid',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ],
    {cwd, stdio: 'pipe'}
  );
};

const spawnCli = (cwd: string, args: string[]): ReturnType<typeof spawnSync> =>
  spawnSync(TSX_BINARY, [CLI_ENTRY, ...args], {cwd, encoding: 'utf8'});

const VERSION_ONE_LEDGER = JSON.stringify({declines: [], version: 1});
const VERSION_TWO_LEDGER = JSON.stringify({declines: [], version: 2});
const SNAPSHOT_FIXTURE = '{"reviewed":"snapshot"}';

describe('relocateCodifyState', () => {
  let temporaryRoot: string;
  let root: string;

  const earlierDirectory = (): string =>
    path.join(root, '.gaia', 'local', 'harden');
  const currentDirectory = (): string =>
    path.join(root, '.gaia', 'local', 'codify');

  const seedEarlier = (files: Record<string, string>): void => {
    mkdirSync(earlierDirectory(), {recursive: true});

    for (const [name, contents] of Object.entries(files)) {
      writeFileSync(path.join(earlierDirectory(), name), contents);
    }
  };

  beforeEach(() => {
    temporaryRoot = realpathSync(
      mkdtempSync(path.join(tmpdir(), 'gaia-codify-state-dir-'))
    );
    root = path.join(temporaryRoot, 'main');
    mkdirSync(root);
    git(root, 'init', '-q', '-b', 'main');
    writeFileSync(path.join(root, 'README.md'), 'fixture\n');
    git(root, 'add', 'README.md');
    git(root, 'commit', '-q', '-m', 'fixture');
  });

  afterEach(() => {
    rmSync(temporaryRoot, {force: true, recursive: true});
  });

  test('moves an earlier-only directory whole, byte for byte', () => {
    seedEarlier({
      'declines.json': VERSION_TWO_LEDGER,
      'reviewed.json': SNAPSHOT_FIXTURE,
    });

    expect(relocateCodifyState(root, root)).toBe('moved');
    expect(existsSync(earlierDirectory())).toBe(false);
    expect(
      readFileSync(path.join(currentDirectory(), 'declines.json'), 'utf8')
    ).toBe(VERSION_TWO_LEDGER);
    expect(
      readFileSync(path.join(currentDirectory(), 'reviewed.json'), 'utf8')
    ).toBe(SNAPSHOT_FIXTURE);
  });

  test('keeps a current-only directory untouched', () => {
    mkdirSync(currentDirectory(), {recursive: true});
    writeFileSync(path.join(currentDirectory(), 'reviewed.json'), 'current');

    expect(relocateCodifyState(root, root)).toBe('kept-new');
    expect(
      readFileSync(path.join(currentDirectory(), 'reviewed.json'), 'utf8')
    ).toBe('current');
  });

  test('keeps the current directory and leaves the earlier one when both exist', () => {
    seedEarlier({'reviewed.json': 'earlier'});
    mkdirSync(currentDirectory(), {recursive: true});
    writeFileSync(path.join(currentDirectory(), 'reviewed.json'), 'current');

    expect(relocateCodifyState(root, root)).toBe('kept-new');
    expect(
      readFileSync(path.join(currentDirectory(), 'reviewed.json'), 'utf8')
    ).toBe('current');
    expect(
      readFileSync(path.join(earlierDirectory(), 'reviewed.json'), 'utf8')
    ).toBe('earlier');
  });

  test('leaves a version-1 ledger where it is and moves the rest', () => {
    seedEarlier({
      'declines.json': VERSION_ONE_LEDGER,
      'reviewed.json': SNAPSHOT_FIXTURE,
    });

    expect(relocateCodifyState(root, root)).toBe('moved-except-v1-ledger');
    expect(
      readFileSync(path.join(earlierDirectory(), 'declines.json'), 'utf8')
    ).toBe(VERSION_ONE_LEDGER);
    expect(existsSync(path.join(currentDirectory(), 'declines.json'))).toBe(
      false
    );
    expect(
      readFileSync(path.join(currentDirectory(), 'reviewed.json'), 'utf8')
    ).toBe(SNAPSHOT_FIXTURE);
    expect(existsSync(path.join(earlierDirectory(), 'reviewed.json'))).toBe(
      false
    );
  });

  test('moves a directory whose ledger is version 2', () => {
    seedEarlier({'declines.json': VERSION_TWO_LEDGER});

    expect(relocateCodifyState(root, root)).toBe('moved');
    expect(existsSync(path.join(currentDirectory(), 'declines.json'))).toBe(
      true
    );
    expect(existsSync(earlierDirectory())).toBe(false);
  });

  test('reports none when neither directory exists', () => {
    expect(relocateCodifyState(root, root)).toBe('none');
    expect(existsSync(currentDirectory())).toBe(false);
  });

  test('skips from a linked worktree and touches nothing', () => {
    seedEarlier({
      'declines.json': VERSION_TWO_LEDGER,
      'reviewed.json': SNAPSHOT_FIXTURE,
    });
    const worktree = path.join(temporaryRoot, 'linked');
    git(root, 'worktree', 'add', '-q', '-b', 'linked', worktree);

    expect(relocateCodifyState(root, worktree)).toBe(
      'skipped-not-main-checkout'
    );
    expect(existsSync(currentDirectory())).toBe(false);
    expect(
      readFileSync(path.join(earlierDirectory(), 'declines.json'), 'utf8')
    ).toBe(VERSION_TWO_LEDGER);
    expect(
      readFileSync(path.join(earlierDirectory(), 'reviewed.json'), 'utf8')
    ).toBe(SNAPSHOT_FIXTURE);
  });

  test('skips a directory that is not a git repository', () => {
    const plain = path.join(temporaryRoot, 'plain');
    mkdirSync(path.join(plain, '.gaia', 'local', 'harden'), {recursive: true});

    expect(relocateCodifyState(plain, plain)).toBe('skipped-not-main-checkout');
    expect(existsSync(path.join(plain, '.gaia', 'local', 'codify'))).toBe(
      false
    );
  });

  describe('at the command level', () => {
    test('codify-ledger list moves the earlier state before reading it', () => {
      seedEarlier({'declines.json': VERSION_TWO_LEDGER});

      const result = spawnCli(root, ['codify-ledger', 'list']);

      expect(result.status).toBe(0);
      expect(existsSync(earlierDirectory())).toBe(false);
      expect(existsSync(path.join(currentDirectory(), 'declines.json'))).toBe(
        true
      );
    });

    test('codify-tally --help leaves the earlier state in place', () => {
      seedEarlier({'declines.json': VERSION_TWO_LEDGER});

      const result = spawnCli(root, ['codify-tally', '--help']);

      expect(result.status).toBe(0);
      expect(existsSync(earlierDirectory())).toBe(true);
      expect(existsSync(currentDirectory())).toBe(false);
    });

    test('an unknown codify-ledger verb leaves the earlier state in place', () => {
      seedEarlier({'declines.json': VERSION_TWO_LEDGER});

      const result = spawnCli(root, ['codify-ledger', 'not-a-verb']);

      expect(result.status).not.toBe(0);
      expect(existsSync(earlierDirectory())).toBe(true);
      expect(existsSync(currentDirectory())).toBe(false);
    });

    test('a usage error inside a known verb leaves the earlier state in place', () => {
      seedEarlier({'declines.json': VERSION_TWO_LEDGER});

      const result = spawnCli(root, ['codify-ledger', 'record']);

      expect(result.status).not.toBe(0);
      expect(existsSync(earlierDirectory())).toBe(true);
      expect(existsSync(currentDirectory())).toBe(false);
    });
  });

  describe('in the tally run', () => {
    beforeEach(() => {
      vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
      vi.spyOn(runProcess, 'runGh').mockReturnValue({
        exitCode: 4,
        stderr: 'gh: not authenticated',
        stdout: '',
      });
    });

    afterEach(() => {
      vi.restoreAllMocks();
    });

    test('moves the earlier state before the first state read', () => {
      seedEarlier({'reviewed.json': SNAPSHOT_FIXTURE});
      vi.spyOn(process.stderr, 'write').mockImplementation(() => true);

      runTally([], {cwd: root});

      expect(existsSync(earlierDirectory())).toBe(false);
      expect(existsSync(path.join(currentDirectory(), 'reviewed.json'))).toBe(
        true
      );
    });
  });
});
