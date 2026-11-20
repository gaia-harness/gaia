/**
 * Focus: the two properties a call site depends on and cannot see. `gitZArgs`
 * puts `-z` in a position every listing verb accepts, which is what leaves the
 * caller no position to omit it from; and `splitZStream` drops empty records
 * without trimming, because `-z` permits whitespace inside a path but leaves
 * no terminator to strip.
 *
 * The end-to-end property, that a real git invocation built this way returns a
 * non-ASCII path unquoted, is pinned by the canary suites beside each call
 * site rather than here, since it needs a git fixture.
 */
import {describe, expect, test} from 'vitest';
import {gitZArgs, splitZStream} from './git-z.js';

const QUOTEPATH = ['-c', 'core.quotepath=false'];

describe('gitZArgs', () => {
  test.each(
    [
      {
        args: ['-r', '-l', 'HEAD', '--', 'wiki/'],
        expected: [
          ...QUOTEPATH,
          'ls-tree',
          '-z',
          '-r',
          '-l',
          'HEAD',
          '--',
          'wiki/',
        ],
        name: 'puts -z immediately after the verb, ahead of the caller arguments',
        verb: 'ls-tree',
      },
      {
        args: undefined,
        expected: [...QUOTEPATH, 'ls-files', '-z'],
        name: 'carries both flags for a verb that takes no further arguments',
        verb: 'ls-files',
      },
      {
        args: ['--name-only', '-r', 'HEAD'],
        expected: [
          ...QUOTEPATH,
          'diff-tree',
          '-z',
          '--name-only',
          '-r',
          'HEAD',
        ],
        name: 'never lets a caller argument precede the flags it is given for',
        verb: 'diff-tree',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {args, expected, verb}) => {
    expect(gitZArgs(verb, args)).toEqual(expected);
  });
});

describe('splitZStream', () => {
  test.each(
    [
      {
        expected: ['wiki/a.md', 'wiki/b.md'],
        name: 'drops the empty record a NUL-terminated stream ends with',
        stream: 'wiki/a.md\0wiki/b.md\0',
      },
      {
        expected: [],
        name: 'returns nothing for the empty stream a listing with no match emits',
        stream: '',
      },
      {
        expected: ['wiki/"quoted".md'],
        name: 'never unquotes, since -z emits raw bytes a name may legally contain',
        stream: 'wiki/"quoted".md\0',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {expected, stream}) => {
    expect(splitZStream(stream)).toEqual(expected);
  });
});
