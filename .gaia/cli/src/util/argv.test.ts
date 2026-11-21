/**
 * Strategy: all three primitives are pure, so every case calls them directly.
 * The divergence rows are the point of the suite: `takeValue` and
 * `takeNonFlagValue` disagree on exactly one input shape, and both answers are
 * shipped, so a change that collapses them into one semantic fails here rather
 * than silently at whichever call sites were relaxed or tightened.
 */
import {describe, expect, test} from 'vitest';
import {lookupOwn, takeNonFlagValue, takeValue} from './argv.js';

const TABLE: Readonly<Partial<Record<string, string>>> = {
  '--out': 'out',
  build: 'build',
};

describe('lookupOwn', () => {
  test.each(
    [
      {
        expected: 'build',
        key: 'build',
        name: 'returns the value for an own key',
      },
      {
        expected: undefined,
        key: 'bogus',
        name: 'returns undefined for an absent key',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {expected, key}) => {
    expect(lookupOwn(TABLE, key)).toBe(expected);
  });
});

const MISSING = {message: '--out requires a value', ok: false};

// The last two rows are the divergence: the readers disagree on a
// --flag-shaped value, and both answers are shipped.
describe('takeValue and takeNonFlagValue', () => {
  test.each(
    [
      {
        argv: ['--out', 'file.txt'],
        expected: {ok: true, value: 'file.txt'},
        name: 'takeValue reads the element at index',
        reader: takeValue,
      },
      {
        argv: ['--out'],
        expected: MISSING,
        name: 'takeValue reports a missing value past the end of argv',
        reader: takeValue,
      },
      {
        argv: ['--out', ''],
        expected: {ok: true, value: ''},
        name: 'takeValue reads an empty string as a value',
        reader: takeValue,
      },
      {
        argv: ['--out', 'file.txt'],
        expected: {ok: true, value: 'file.txt'},
        name: 'takeNonFlagValue reads the element at index',
        reader: takeNonFlagValue,
      },
      {
        argv: ['--out'],
        expected: MISSING,
        name: 'takeNonFlagValue reports a missing value past the end of argv',
        reader: takeNonFlagValue,
      },
      {
        argv: ['--out', '-x'],
        expected: {ok: true, value: '-x'},
        name: 'takeNonFlagValue reads a single-dash element as a value',
        reader: takeNonFlagValue,
      },
      {
        argv: ['--out', '--json'],
        expected: {ok: true, value: '--json'},
        name: 'takeValue consumes the following flag as the value',
        reader: takeValue,
      },
      {
        argv: ['--out', '--json'],
        expected: MISSING,
        name: 'takeNonFlagValue reports a missing value instead',
        reader: takeNonFlagValue,
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {argv, expected, reader}) => {
    expect(reader(argv, 1, '--out')).toEqual(expected);
  });
});
