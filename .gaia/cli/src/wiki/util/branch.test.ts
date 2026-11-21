/**
 * Focus: the classification is only as trustworthy as the parse behind it.
 * Both callers refuse to act on a working tree carrying non-wiki changes, so a
 * path git reports in a shape the parse mishandles does not merely print
 * wrong, it takes the wrong branch. Under `-z` git emits raw bytes and gives a
 * rename origin its own record, which is what keeps a spaced or non-ASCII
 * wiki page (nearly every GAIA wiki page has a space in its filename) on the
 * wiki side of the split.
 */
import {describe, expect, test} from 'vitest';
import type {SpawnSyncReturns} from 'node:child_process';
import {inspectWorkingTree} from './branch.js';
import type {CommandRunner} from './branch.js';

const okResult = (stdout: string): SpawnSyncReturns<string> => ({
  output: ['', stdout, ''] as never,
  pid: 0,
  signal: null,
  status: 0,
  stderr: '',
  stdout,
});

const runnerReturning =
  (stdout: string): CommandRunner =>
  () =>
    okResult(stdout);

describe('inspectWorkingTree', () => {
  test('asks git for NUL-delimited records, which the parse depends on', () => {
    const seen: string[][] = [];

    inspectWorkingTree('/repo', (_command, args) => {
      seen.push([...args]);

      return okResult('');
    });

    expect(seen).toEqual([['status', '--porcelain=v1', '-z', '-uall']]);
  });

  const inspectWorkingTreeClassificationCases: readonly {
    hasNonWikiChanges: boolean;
    hasWikiChanges: boolean;
    name: string;
    paths: readonly string[];
    stdout: string;
  }[] = [
    {
      hasNonWikiChanges: false,
      hasWikiChanges: true,
      name: 'classifies a spaced wiki path as a wiki change',
      paths: ['wiki/concepts/Wiki Sync.md'],
      stdout: ' M wiki/concepts/Wiki Sync.md\0',
    },
    {
      hasNonWikiChanges: false,
      hasWikiChanges: true,
      name: 'handles an added (untracked) spaced wiki page',
      paths: ['wiki/decisions/TDD RED Verification.md'],
      stdout: '?? wiki/decisions/TDD RED Verification.md\0',
    },
    {
      hasNonWikiChanges: true,
      hasWikiChanges: false,
      name: 'flags a spaced non-wiki path as a non-wiki change',
      paths: ['app/some dir/a file.ts'],
      stdout: ' M app/some dir/a file.ts\0',
    },
    {
      hasNonWikiChanges: true,
      hasWikiChanges: false,
      name: 'reports both halves of a rename',
      paths: ['app/new.ts', 'app/old.ts'],
      stdout: 'R  app/new.ts\0app/old.ts\0',
    },
    {
      hasNonWikiChanges: false,
      hasWikiChanges: true,
      name: 'keeps a non-ASCII wiki rename on the wiki side of the split',
      paths: ['wiki/concepts/Café Notes.md', 'wiki/concepts/Cafe Notes.md'],
      stdout: 'R  wiki/concepts/Café Notes.md\0wiki/concepts/Cafe Notes.md\0',
    },
    {
      hasNonWikiChanges: true,
      hasWikiChanges: true,
      name: 'classifies a mix of a wiki edit and a non-wiki edit',
      paths: ['wiki/concepts/Wiki Sync.md', 'package.json'],
      stdout: ' M wiki/concepts/Wiki Sync.md\0 M package.json\0',
    },
    {
      hasNonWikiChanges: false,
      hasWikiChanges: false,
      name: 'reports a clean tree as neither wiki nor non-wiki',
      paths: [],
      stdout: '',
    },
  ];

  test.each(
    inspectWorkingTreeClassificationCases.map((row) => [row.name, row] as const)
  )('%s', (_name, {hasNonWikiChanges, hasWikiChanges, paths, stdout}) => {
    const status = inspectWorkingTree('/repo', runnerReturning(stdout));

    expect(status.paths).toEqual(paths);
    expect(status.hasWikiChanges).toBe(hasWikiChanges);
    expect(status.hasNonWikiChanges).toBe(hasNonWikiChanges);
  });
});
