import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {spawnSync} from 'node:child_process';
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createRuleContext} from './context.js';
import {createScratchProject} from './test-support.js';
import type {ScratchProject} from './test-support.js';

const QUERIES = [
  'output/',
  'output',
  'runtime.log',
  'keep.log',
  'build/nested/file',
  'tracked.log',
  'linked/beyond',
  'plain.md',
];

let scratch: ScratchProject;
let shimDirectory: string;
let savedPath: string | undefined;

const shimLog = (): string => path.join(shimDirectory, 'calls.log');

const checkIgnoreSpawns = (): number => {
  try {
    return readFileSync(shimLog(), 'utf8')
      .split('\n')
      .filter((line) => line.includes('check-ignore')).length;
  } catch {
    return 0;
  }
};

const perPathAnswer = (relative: string): boolean | undefined => {
  const spawned = spawnSync(
    'git',
    ['-C', scratch.root, 'check-ignore', '-q', '--', relative],
    {encoding: 'utf8'}
  );

  if (spawned.status === 0) return true;

  return spawned.status === 1 ? false : undefined;
};

const contextFor = (inGit: boolean) =>
  createRuleContext({
    allTrackedPaths: new Set(),
    files: [],
    inGit,
    knownRuleIds: new Set(),
    projectModel: 'unresolved',
    root: scratch.root,
  });

beforeEach(() => {
  scratch = createScratchProject({
    classifier: 'none',
    files: {
      '.gitignore': 'output/\n*.log\n!keep.log\nbuild\n',
      'real/kept.md': '# kept\n',
      'tracked.log': 'forced\n',
    },
    git: true,
  });
  symlinkSync('real', path.join(scratch.root, 'linked'));
  // An ignored name that is tracked anyway, which git never reports ignored.
  spawnSync('git', ['-C', scratch.root, 'add', '-f', 'tracked.log']);
  spawnSync('git', [
    '-C',
    scratch.root,
    'commit',
    '-q',
    '--no-verify',
    '-m',
    'force',
  ]);

  // A logging shim ahead of the real git, so the test counts the spawns.
  const realGit = spawnSync('sh', ['-c', 'command -v git'], {
    encoding: 'utf8',
  }).stdout.trim();

  shimDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-git-shim-'));
  mkdirSync(shimDirectory, {recursive: true});
  writeFileSync(
    path.join(shimDirectory, 'git'),
    `#!/bin/sh\nprintf '%s\\n' "$*" >> '${shimLog()}'\nexec '${realGit}' "$@"\n`
  );
  chmodSync(path.join(shimDirectory, 'git'), 0o755);
  savedPath = process.env.PATH;
  process.env.PATH = `${shimDirectory}${path.delimiter}${savedPath ?? ''}`;
});

afterEach(() => {
  process.env.PATH = savedPath;
  rmSync(shimDirectory, {force: true, recursive: true});
  scratch.cleanup();
});

describe('gitIgnored inside runWithBatchedIgnores', () => {
  test('answers exactly as one git check-ignore per path would', () => {
    const expected = QUERIES.map((query) => perPathAnswer(query));
    const {context, runWithBatchedIgnores} = contextFor(true);

    const answers = runWithBatchedIgnores(() =>
      QUERIES.map((query) => context.gitIgnored(query))
    );

    expect(answers).toEqual(expected);
    expect(expected).toContain(undefined);
  });

  test('spends a bounded number of git spawns, not one per path', () => {
    const many = Array.from({length: 200}, (_, index) => `dir${index}/a.log`);
    const {context, runWithBatchedIgnores} = contextFor(true);

    const answers = runWithBatchedIgnores(() =>
      many.map((query) => context.gitIgnored(query))
    );

    expect(answers.every((answer) => answer === true)).toBe(true);
    expect(checkIgnoreSpawns()).toBe(1);
  });

  test('a path git rejects aborts only its own half of the batch', () => {
    const many = Array.from({length: 8}, (_, index) => `dir${index}/a.log`);
    const {context, runWithBatchedIgnores} = contextFor(true);

    const answers = runWithBatchedIgnores(() =>
      [...many, 'linked/beyond'].map((query) => context.gitIgnored(query))
    );

    expect(answers).toEqual([...many.map(() => true), undefined]);
    // The batch of 9, its halves of 5 and 4, the failing 4 as two pairs, the
    // failing pair as two singles, and the rejected path's per-path call.
    expect(checkIgnoreSpawns()).toBe(8);
  });

  test('a lookup only discovered after an earlier answer still resolves', () => {
    const {context, runWithBatchedIgnores} = contextFor(true);

    const answers = runWithBatchedIgnores(() =>
      context.gitIgnored('first.log') === true ?
        [context.gitIgnored('output/'), context.gitIgnored('plain.md')]
      : []
    );

    expect(answers).toEqual([true, false]);
    expect(checkIgnoreSpawns()).toBe(2);
  });

  test('outside git it answers undefined and spawns nothing', () => {
    const {context, runWithBatchedIgnores} = contextFor(false);

    const answers = runWithBatchedIgnores(() =>
      QUERIES.map((query) => context.gitIgnored(query))
    );

    expect(answers.every((answer) => answer === undefined)).toBe(true);
    expect(checkIgnoreSpawns()).toBe(0);
  });
});

describe('gitIgnored outside runWithBatchedIgnores', () => {
  test('answers a single lookup directly and caches it', () => {
    const {context} = contextFor(true);

    expect(context.gitIgnored('runtime.log')).toBe(true);
    expect(context.gitIgnored('runtime.log')).toBe(true);
    expect(context.gitIgnored('keep.log')).toBe(false);
    expect(checkIgnoreSpawns()).toBe(2);
  });
});
