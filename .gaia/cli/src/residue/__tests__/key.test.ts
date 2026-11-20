import {describe, expect, test} from 'vitest';
import {
  MAX_LINE,
  normalizeRepoRelativePath,
  parseKey,
  parseKeyLine,
  parseWrappedKeys,
  sameCoordinate,
} from '../key.js';
import type {Validated} from '../key.js';

const refusal = (result: {ok: boolean; reason?: string}): string => {
  if (result.ok) {
    throw new Error('expected a refusal, got a validated value');
  }

  return result.reason ?? '';
};

const validated = <T>(result: Validated<T>): T => {
  if (!result.ok) {
    throw new Error(
      `expected a validated value, got a refusal: ${result.reason}`
    );
  }

  return result.value;
};

const wrapped = (inner: string): string => `<!-- gaia-debt-key: ${inner} -->`;

describe('normalizeRepoRelativePath refuses each unsafe path', () => {
  test.each<{cases: [string, string][]; title: string}>([
    {
      cases: [
        ['/etc/passwd', 'absolute prefix'],
        [String.raw`C:\Windows`, 'absolute prefix'],
        [String.raw`\\host\share`, 'absolute prefix'],
      ],
      title: 'refuses an absolute path, naming the absolute prefix',
    },
    {
      cases: [
        ['app/../../etc/passwd', 'traversal segment'],
        ['app/./../../x', 'traversal segment'],
      ],
      title: 'refuses a traversal path, before and after normalization',
    },
    {
      cases: [['--upload-pack=x', 'leading dash']],
      title: 'refuses a leading-dash path with its own reason',
    },
    {
      cases: [
        ['app/foo\nbar.ts', 'newline'],
        ['app/foo\rbar.ts', 'carriage return'],
        ['app/foo\0bar.ts', 'NUL'],
      ],
      title: 'refuses an embedded control character, naming which one',
    },
    {
      cases: [
        ['', 'empty'],
        ['./', 'normalizes to empty'],
      ],
      title: 'refuses an empty path and one that normalizes to empty',
    },
  ])('$title', ({cases}) => {
    for (const [input, reason] of cases) {
      expect(refusal(normalizeRepoRelativePath(input))).toContain(reason);
    }
  });
});

describe('normalizeRepoRelativePath accepts safe forms', () => {
  test.each<{cases: [string, string][]; title: string}>([
    {
      cases: [
        ['app/./services//foo.ts', 'app/services/foo.ts'],
        ['app/services/', 'app/services'],
        ['.gaia/scripts/w.sh', '.gaia/scripts/w.sh'],
      ],
      title:
        'collapses dot segments, repeated separators, and a trailing separator',
    },
    {
      cases: [['app/my file.ts', 'app/my file.ts']],
      title: 'accepts a path carrying a space',
    },
  ])('$title', ({cases}) => {
    for (const [input, value] of cases) {
      expect(normalizeRepoRelativePath(input)).toStrictEqual({
        ok: true,
        value,
      });
    }
  });
});

const refusedFor = (reason: string): object => ({
  ok: false,
  reason: expect.stringContaining(reason),
});

describe('parseKeyLine refuses a bad line and accepts the bounds', () => {
  test.each<{cases: [string, object][]; title: string}>([
    {
      cases: [
        ['-1', refusedFor('sign')],
        ['+5', refusedFor('sign')],
      ],
      title: 'refuses a signed line',
    },
    {
      cases: [
        ['1e3', refusedFor('bare digit run')],
        ['4 ', refusedFor('bare digit run')],
      ],
      title: 'refuses a line that is not a bare digit run',
    },
    {
      cases: [['042', refusedFor('leading zero')]],
      title: 'refuses a leading zero',
    },
    {
      cases: [
        ['0', refusedFor('below 1')],
        [String(MAX_LINE + 1), refusedFor('exceeds the maximum')],
      ],
      title: 'refuses a line below 1 and one above MAX_LINE',
    },
    {
      cases: [
        ['1', {ok: true, value: 1}],
        [String(MAX_LINE), {ok: true, value: MAX_LINE}],
      ],
      title: 'accepts the bounds themselves',
    },
  ])('$title', ({cases}) => {
    for (const [input, expected] of cases) {
      expect(parseKeyLine(input)).toEqual(expected);
    }
  });
});

describe('parseKey parses the gate grammar', () => {
  test.each<{cases: [string, object][]; title: string}>([
    {
      cases: [
        [
          'v1 class=a/one path=app/./one.ts line=42',
          {
            ok: true,
            value: {
              class: 'a/one',
              line: 42,
              path: 'app/one.ts',
              version: 'v1',
            },
          },
        ],
      ],
      title: 'parses a valid key into a normalized coordinate',
    },
    {
      cases: [
        ['class=a/one path=app/one.ts line=42', refusedFor('v1 version token')],
      ],
      title: 'refuses a key missing the v1 version token',
    },
    {
      cases: [
        [
          'v1 class=a/one path=/etc/passwd line=42',
          refusedFor('absolute prefix'),
        ],
        ['v1 class=a/one path=app/one.ts line=0', refusedFor('below 1')],
        ['v1 class=a/one path=app/one\nx.ts line=42', refusedFor('newline')],
      ],
      title: 'routes a field refusal through with its own reason',
    },
  ])('$title', ({cases}) => {
    for (const [input, expected] of cases) {
      expect(parseKey(input, 'gate')).toEqual(expected);
    }
  });
});

describe('sameCoordinate compares normalized coordinates', () => {
  test.each<{
    expected: boolean;
    left: {line: number; path: string};
    right: {line: number; path: string};
    title: string;
  }>([
    {
      expected: true,
      left: {line: 42, path: 'app/./services//foo.ts'},
      right: {line: 42, path: 'app/services/foo.ts'},
      title: 'compares on the normalized path form',
    },
    {
      expected: false,
      left: {line: 4, path: 'app/services/foo.ts'},
      right: {line: 42, path: 'app/services/foo.ts'},
      title: 'separates two lines that differ',
    },
    {
      expected: false,
      left: {line: 1, path: '/etc/passwd'},
      right: {line: 1, path: '/etc/passwd'},
      title: 'treats an unvalidatable path as no match rather than a throw',
    },
  ])('$title', ({expected, left, right}) => {
    expect(sameCoordinate(left, right)).toBe(expected);
  });

  test('ignores class: two keys differing only in class share one coordinate', () => {
    const left = validated(
      parseKey('v1 class=a/one path=app/one.ts line=7', 'gate')
    );
    const right = validated(
      parseKey('v1 class=z/other path=app/one.ts line=7', 'gate')
    );

    expect(left.class).not.toBe(right.class);
    expect(sameCoordinate(left, right)).toBe(true);
  });
});

describe('parseWrappedKeys, the filer grammar', () => {
  test('returns a key carrying no v1 token, which the gate grammar refuses', () => {
    const body = `Some issue prose.\n${wrapped('class=a/one path=app/one.ts line=5')}\n`;

    expect(parseWrappedKeys(body)).toStrictEqual([
      {line: 5, path: 'app/one.ts'},
    ]);
    expect(parseKey('class=a/one path=app/one.ts line=5', 'gate').ok).toBe(
      false
    );
  });

  test('parseWrappedKeys and parseKey agree on a spaced-path key', () => {
    const inner = 'v1 class=a/one path=app/my file.ts line=5';

    expect(parseWrappedKeys(wrapped(inner))).toStrictEqual([
      {line: 5, path: 'app/my file.ts'},
    ]);
    expect(validated(parseKey(inner, 'gate'))).toMatchObject({
      line: 5,
      path: 'app/my file.ts',
    });
  });

  test.each<{cases: [string, object[]][]; title: string}>([
    {
      cases: [
        [
          [
            wrapped('v1 class=a/one path=app/one.ts line=11'),
            wrapped('v1 class=a/abs path=/etc/passwd line=12'),
            wrapped('v1 class=a/up path=app/../../x line=13'),
            wrapped('v1 class=a/two path=app/two.ts line=22'),
          ].join('\n'),
          [
            {line: 11, path: 'app/one.ts'},
            {line: 22, path: 'app/two.ts'},
          ],
        ],
      ],
      title: 'returns every key in body order and drops one it cannot validate',
    },
    {
      cases: [[wrapped('v1 class=a/one path=app/one.ts line=x'), []]],
      title: 'drops a key whose line is not a digit run',
    },
    {
      cases: [
        ['This issue is about path=app/one.ts line=5 in prose.', []],
        ['gaia-debt-key: path=app/one.ts line=5', []],
      ],
      title: 'returns nothing for issue prose that merely mentions path=',
    },
  ])('$title', ({cases}) => {
    for (const [body, expected] of cases) {
      expect(parseWrappedKeys(body)).toStrictEqual(expected);
    }
  });
});
