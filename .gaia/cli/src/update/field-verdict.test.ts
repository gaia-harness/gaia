import {describe, expect, test} from 'vitest';
import {occupiedBucket, VERDICT_ROWS} from './field-verdict-table-fixture.js';
import {
  absent,
  classifyTriples,
  computeVerdict,
  extractDeferredBaselines,
  recommend,
  triplesWithDeferred,
} from './field-verdict.js';
import type {
  Presence,
  Recommendation,
  Triple,
  VerdictItem,
} from './field-verdict.js';

const presence = (value: number | undefined): Presence =>
  value === undefined ? absent : {has: true, value};

const tripleOf = (row: (typeof VERDICT_ROWS)[number], key = 'k'): Triple => ({
  a: presence(row.adopter),
  b: presence(row.baseline),
  key,
  kind: 'key',
  l: presence(row.latest),
});

const conflictItem = (
  overrides: Partial<VerdictItem> & Pick<VerdictItem, 'adopter' | 'latest'>
): VerdictItem => ({
  key: 'dep',
  kind: 'entry',
  section: 'dependencies',
  versionValued: true,
  ...overrides,
});

describe('classifyTriples verdict table', () => {
  test.each(VERDICT_ROWS)('$name', (row) => {
    const report = classifyTriples([tripleOf(row)]);

    expect(occupiedBucket(report)).toBe(row.expected);
    expect(report.applied[0]?.reason).toBe(row.reason);
  });

  test('a key the adopter removed is never in applied', () => {
    const report = classifyTriples([
      tripleOf({
        adopter: undefined,
        baseline: 1,
        expected: 'keptRemoved',
        latest: 2,
        name: 'removed',
      }),
    ]);

    expect(report.applied).toEqual([]);
    expect(report.keptRemoved).toHaveLength(1);
  });

  test('the computed verdict names the bucket, so a mutated row is caught', () => {
    expect(
      computeVerdict({a: absent, b: absent, l: {has: true, value: 2}})
    ).toBe('added');
    expect(
      computeVerdict({
        a: absent,
        b: {has: true, value: 1},
        l: {has: true, value: 2},
      })
    ).toBe('keptRemoved');
  });

  test('every conflict carries versionValued and a recommendation', () => {
    const report = classifyTriples([
      {
        ...tripleOf(VERDICT_ROWS[3] as (typeof VERDICT_ROWS)[number]),
        versionValued: true,
      },
    ]);

    expect(report.conflicts[0]?.versionValued).toBe(true);
    expect(report.conflicts[0]?.recommendation).toBeDefined();
  });
});

const NON_SEMVER_SPECS = [
  'workspace:*',
  'catalog:',
  'npm:foo@1',
  'git+https://example.com/a.git',
];

const RECOMMEND_ROWS: {
  expected: Partial<Recommendation>;
  items: VerdictItem[];
  name: string;
}[] = [
  {
    expected: {option: 'higher', side: 'gaia', value: '^5.2.0'},
    items: [conflictItem({adopter: '^5.1.0', latest: '^5.2.0'})],
    name: 'a higher GAIA range recommends higher/gaia',
  },
  {
    expected: {option: 'higher', side: 'adopter', value: '~6.0.0'},
    items: [conflictItem({adopter: '~6.0.0', latest: '^5.9.0'})],
    name: 'a higher adopter range recommends higher/adopter',
  },
  {
    expected: {option: 'keep'},
    items: [conflictItem({adopter: '^5.1.0', latest: '~5.1.0'})],
    name: 'equal lower bounds recommend keep',
  },
  ...NON_SEMVER_SPECS.map((spec) => ({
    expected: {option: 'keep' as const},
    items: [
      conflictItem({adopter: spec, latest: '^1.0.0'}),
      conflictItem({adopter: '^1.0.0', latest: spec}),
    ],
    name: `a non-semver spec ${spec} on either side recommends keep`,
  })),
  {
    expected: {option: 'higher', side: 'gaia', value: 'pnpm@11.3.0'},
    items: [
      {
        adopter: 'pnpm@11.2.0+sha512.abc',
        key: 'packageManager',
        kind: 'key',
        latest: 'pnpm@11.3.0',
        versionValued: true,
      },
    ],
    name: 'packageManager compares the version after @ with the hash stripped',
  },
  {
    expected: {option: 'keep', reason: expect.stringMatching(/\S/u)},
    items: [conflictItem({adopter: 'a', latest: 'b', versionValued: false})],
    name: 'a non-version conflict recommends keep with a reason',
  },
];

describe('recommend', () => {
  test.each(RECOMMEND_ROWS.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {expected, items}) => {
      for (const item of items) {
        expect(recommend(item)).toMatchObject(expected);
      }
    }
  );
});

describe('extractDeferredBaselines', () => {
  test('splits on the first equals sign and removes the pairs from argv', () => {
    const result = extractDeferredBaselines([
      '--baseline',
      'b',
      '--deferred-baseline',
      'devDependencies.@types/node=fixtures/a=b.json',
      '--json',
    ]);

    expect(result).toEqual({
      deferred: new Map([['devDependencies.@types/node', 'fixtures/a=b.json']]),
      ok: true,
      rest: ['--baseline', 'b', '--json'],
    });
  });

  test.each([
    ['rejects nofile', ['--deferred-baseline', 'nofile']],
    ['rejects =file', ['--deferred-baseline', '=file']],
    ['rejects key=', ['--deferred-baseline', 'key=']],
    ['rejects a flag with no value', ['--deferred-baseline']],
  ])('%s', (_name, argv) => {
    expect(extractDeferredBaselines(argv).ok).toBe(false);
  });
});

const buildTwoKeys = (baseline: Record<string, number>): Triple[] =>
  ['x', 'y'].map((key) => ({
    a: presence(1),
    b: presence(baseline[key]),
    key,
    kind: 'key' as const,
    l: presence(2),
  }));

describe('triplesWithDeferred', () => {
  test('a deferred key reads its baseline from the deferred root only', () => {
    const triples = triplesWithDeferred(
      buildTwoKeys,
      {x: 2, y: 2},
      new Map([['x', {x: 1, y: 99}]])
    );
    const report = classifyTriples(triples);

    expect(report.applied.map((item) => item.key)).toEqual(['x']);
    expect(report.applied).toHaveLength(1);
  });
});
