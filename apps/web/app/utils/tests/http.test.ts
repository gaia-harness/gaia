import {describe, expect, test} from 'vitest';
import {resolveLocalRedirect} from '../http';

const localTargets = [
  ['same-origin path', '/', '/'],
  ['same-origin path', '/dashboard', '/dashboard'],
  ['same-origin path', '/a/b?c=d#e', '/a/b?c=d#e'],
  ['same-origin path', '/en/about?x=1#y', '/en/about?x=1#y'],
  ['resolved path', '/a/../b', '/b'],
  ['resolved path', '/a b', '/a%20b'],
] as const;

const refusedTargets = [
  ['off-site or empty target', '//example.com'],
  ['off-site or empty target', String.raw`/\example.com`],
  ['off-site or empty target', 'https://example.com'],
  ['off-site or empty target', 'https://local.invalid/a'],
  ['off-site or empty target', 'mailto:a@b.com'],
  ['off-site or empty target', 'a/b'],
  ['off-site or empty target', ''],
  ['off-site or empty target', null],
  ['off-site or empty target', undefined],
  ['target the URL parser resolves to another host', '/\t/example.com'],
  ['target the URL parser resolves to another host', '/\n/example.com'],
  ['target the URL parser resolves to another host', '/\r/example.com'],
  ['target the URL parser resolves to another host', '/\t\\example.com'],
  ['target the URL parser resolves to another host', '/\\\t/example.com'],
  ['target whose resolved path starts with two slashes', '/.//example.com'],
  [
    'target whose resolved path starts with two slashes',
    String.raw`/./\example.com`,
  ],
  ['target whose resolved path starts with two slashes', '/a/..//example.com'],
  ['target the URL parser rejects', '//'],
  ['target the URL parser rejects', '/\\'],
  ['target the URL parser rejects', '//['],
  ['target the URL parser rejects', '//a b'],
] as const;

describe('http utils', () => {
  test.each(
    [
      ...localTargets.map(([kind, input, expected]) => ({
        expected,
        input,
        name: `returns the ${kind} ${JSON.stringify(input)}`,
      })),
      ...refusedTargets.map(([kind, input]) => ({
        expected: undefined,
        input,
        name: `refuses the ${kind} ${JSON.stringify(input)}`,
      })),
    ].map((row) => [row.name, row] as const)
  )(
    'resolveLocalRedirect returns local paths and refuses every off-site form: %s',
    (_name, {expected, input}) => {
      expect(resolveLocalRedirect(input)).toBe(expected);
    }
  );
});
