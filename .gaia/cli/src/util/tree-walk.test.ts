import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  collectTreeFiles,
  EVERY_EXTENSION,
  normalizeEntry,
} from './tree-walk.js';

const TS_SOURCE_EXTENSIONS: ReadonlySet<string> = new Set(['.ts']);

const seed = (root: string, relative: string): void => {
  const abs = path.join(root, relative);
  mkdirSync(path.dirname(abs), {recursive: true});
  writeFileSync(abs, '', 'utf8');
};

// The separator is passed rather than read from `path.sep`, so a case can
// assert a POSIX pass-through regardless of which platform runs the suite.
describe('normalizeEntry', () => {
  test.each(
    [
      {
        entry: 'leaf.ts',
        name: 'leaves an entry that carries no separator alone',
        separator: '\\',
      },
      {
        entry: 'nested/leaf.ts',
        name: 'leaves an already-POSIX entry alone',
        separator: '/',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {entry, separator}) => {
    expect(normalizeEntry(entry, separator)).toBe(entry);
  });
});

describe('collectTreeFiles', () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(path.join(tmpdir(), 'gaia-collect-'));
  });

  afterEach(() => {
    rmSync(dir, {force: true, recursive: true});
  });

  test('reaches nested entries and reports them relative to the root', () => {
    seed(dir, 'nested/deep/leaf.ts');

    expect(collectTreeFiles(dir, TS_SOURCE_EXTENSIONS)).toEqual([
      'nested/deep/leaf.ts',
    ]);
  });

  test('reports entries POSIX-separated', () => {
    seed(dir, path.join('nested', 'leaf.ts'));

    const [entry] = collectTreeFiles(dir, TS_SOURCE_EXTENSIONS);

    expect(entry).toBe('nested/leaf.ts');
  });

  test('sorts the entries', () => {
    seed(dir, 'b.ts');
    seed(dir, 'a.ts');
    seed(dir, 'nested/a.ts');

    expect(collectTreeFiles(dir, TS_SOURCE_EXTENSIONS)).toEqual([
      'a.ts',
      'b.ts',
      'nested/a.ts',
    ]);
  });

  // In the last row, an extensionless file and a dotfile are the entries an
  // extension set can never name, so they are what tells "every file" from
  // "every extension anyone listed".
  test.each(
    (
      [
        {
          directories: [],
          expected: ['kept.ts'],
          extensions: TS_SOURCE_EXTENSIONS,
          files: ['kept.ts', 'skipped.md', 'skipped'],
          name: 'keeps only the entries whose extension is in the set',
        },
        {
          directories: [],
          expected: ['shouty.TS'],
          extensions: TS_SOURCE_EXTENSIONS,
          files: ['shouty.TS'],
          name: 'matches the extension case-insensitively',
        },
        {
          directories: [],
          expected: ['prose.md'],
          extensions: new Set(['.md']),
          files: ['prose.md', 'code.ts'],
          name: 'honors a caller-supplied extension set',
        },
        {
          directories: ['empty'],
          expected: ['.gitignore', 'code.ts', 'Makefile', 'nested/prose.md'],
          extensions: EVERY_EXTENSION,
          files: ['code.ts', 'Makefile', '.gitignore', 'nested/prose.md'],
          name: 'keeps every regular file when handed every extension',
        },
      ] as const
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {directories, expected, extensions, files}) => {
    for (const file of files) seed(dir, file);
    for (const directory of directories) mkdirSync(path.join(dir, directory));

    expect(collectTreeFiles(dir, extensions)).toEqual(expected);
  });

  test('throws when the root does not exist', () => {
    expect(() =>
      collectTreeFiles(path.join(dir, 'absent'), TS_SOURCE_EXTENSIONS)
    ).toThrow(/ENOENT/);
  });
});
