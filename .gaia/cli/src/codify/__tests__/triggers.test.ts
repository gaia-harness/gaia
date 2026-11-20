import {describe, expect, test, vi} from 'vitest';
import type {ReviewSnapshot} from '../../schemas/review-snapshot.js';
import type * as MaterialRiseModule from '../material-rise.js';
import {isMaterialRise, TALLY_SCHEMA_VERSION} from '../material-rise.js';
import {evaluateTriggers} from '../triggers.js';
import type {EvaluateTriggersArgs} from '../triggers.js';

// Wraps the REAL isMaterialRise in a vi.fn (case 11a needs a spy that still
// computes the real answer by default; every other case relies on it behaving
// identically to the unmocked function).
vi.mock('../material-rise.js', async (importOriginal) => {
  const actual = await importOriginal<typeof MaterialRiseModule>();

  return {...actual, isMaterialRise: vi.fn(actual.isMaterialRise)};
});

const makeSnapshot = (args: {
  audited: number;
  classes: Record<string, number>;
  schemaVersion?: number;
  unclassified?: null | number;
}): ReviewSnapshot => {
  const share = (count: number): number =>
    args.audited > 0 ? count / args.audited : 0;

  return {
    audited_pr_count: args.audited,
    classes: Object.fromEntries(
      Object.entries(args.classes).map(([findingClass, count]) => [
        findingClass,
        {distinct_pr_count: count, share: share(count)},
      ])
    ),
    reviewed_at: '2026-01-01T00:00:00.000Z',
    tally_schema_version: args.schemaVersion ?? TALLY_SCHEMA_VERSION,
    unclassified:
      args.unclassified == null ?
        null
      : {distinct_pr_count: args.unclassified, share: share(args.unclassified)},
    version: 1,
    window_days: 90,
  };
};

// `candidates` is an ordered tuple list, not a Record: several cases assert
// the trigger order tracks `candidates[]` order, which a plain object's key
// order cannot be relied on to preserve once linted/sorted.
const makeLive = (args: {
  audited: number;
  candidates: readonly (readonly [string, number])[];
  schemaVersion?: number;
  unclassified?: null | number;
}): EvaluateTriggersArgs['live'] => ({
  auditedPrCount: args.audited,
  candidates: args.candidates.map(([finding_class, distinct_pr_count]) => ({
    distinct_pr_count,
    finding_class,
  })),
  tallySchemaVersion: args.schemaVersion ?? TALLY_SCHEMA_VERSION,
  unclassified:
    args.unclassified == null ? null : {distinct_pr_count: args.unclassified},
});

const risingTrigger = (findingClass: string) => [
  {finding_class: findingClass, type: 'rising_class'},
];

describe('evaluateTriggers', () => {
  test('1: no snapshot -> []', () => {
    const result = evaluateTriggers({
      live: makeLive({audited: 400, candidates: []}),
      snapshot: null,
    });

    expect(result).toEqual([]);
  });

  test.each([
    {
      candidates: [
        ['holistic/drifting-duplicate', 10],
        ['holistic/overclaimed-guarantee', 40],
        ['holistic/swallowed-error', 5],
      ],
      classes: {
        'holistic/drifting-duplicate': 10,
        'holistic/overclaimed-guarantee': 40,
      },
      expected: [
        {finding_class: 'holistic/swallowed-error', type: 'new_class'},
      ],
      name: '2: a live candidate absent from the snapshot reads as new_class',
    },
    {
      candidates: [
        ['holistic/swallowed-error', 5],
        ['holistic/n-plus-one', 6],
        ['holistic/overclaimed-guarantee', 40],
      ],
      classes: {'holistic/overclaimed-guarantee': 40},
      expected: [
        {finding_class: 'holistic/swallowed-error', type: 'new_class'},
        {finding_class: 'holistic/n-plus-one', type: 'new_class'},
      ],
      name: '2b: two absent candidates yield two new_class entries in candidates order',
    },
    {
      candidates: [
        ['holistic/swallowed-error', 5],
        ['holistic/drifting-duplicate', 400],
      ],
      classes: {'holistic/drifting-duplicate': 40},
      expected: [
        {finding_class: 'holistic/swallowed-error', type: 'new_class'},
        {finding_class: 'holistic/drifting-duplicate', type: 'rising_class'},
      ],
      name: '8: a combined new_class and rising_class trigger set preserves candidates order',
    },
  ] as {
    candidates: [string, number][];
    classes: Record<string, number>;
    expected: unknown[];
    name: string;
  }[])('$name', ({candidates, classes, expected}) => {
    const result = evaluateTriggers({
      live: makeLive({audited: 400, candidates}),
      snapshot: makeSnapshot({audited: 400, classes}),
    });

    expect(result).toEqual(expected);
  });

  test.each([
    {
      expected: risingTrigger('holistic/overclaimed-guarantee'),
      live: {
        audited: 400,
        candidates: [['holistic/overclaimed-guarantee', 50]],
      },
      name: '3: material rise across the ratio floor',
      snapshot: {audited: 400, classes: {'holistic/overclaimed-guarantee': 40}},
    },
    {
      expected: [],
      live: {
        audited: 400,
        candidates: [['holistic/overclaimed-guarantee', 49]],
      },
      name: '3: refusal just under the ratio floor',
      snapshot: {audited: 400, classes: {'holistic/overclaimed-guarantee': 40}},
    },
    {
      expected: [],
      live: {audited: 400, candidates: [['holistic/swallowed-error', 6]]},
      name: '4: the +3 floor refuses a ratio-only rise',
      snapshot: {audited: 400, classes: {'holistic/swallowed-error': 4}},
    },
    {
      expected: risingTrigger('holistic/swallowed-error'),
      live: {audited: 400, candidates: [['holistic/swallowed-error', 7]]},
      name: '4: the +3 floor passes once the delta reaches it',
      snapshot: {audited: 400, classes: {'holistic/swallowed-error': 4}},
    },
    {
      expected: [],
      live: {
        audited: 800,
        candidates: [
          ['holistic/drifting-duplicate', 20],
          ['holistic/overclaimed-guarantee', 80],
        ],
        unclassified: 240,
      },
      name: '5: proportional growth across a doubled audited-PR base never fires, including unclassified',
      snapshot: {
        audited: 400,
        classes: {
          'holistic/drifting-duplicate': 10,
          'holistic/overclaimed-guarantee': 40,
        },
        unclassified: 120,
      },
    },
    {
      expected: risingTrigger('holistic/overclaimed-guarantee'),
      live: {
        audited: 32,
        candidates: [['holistic/overclaimed-guarantee', 8]],
      },
      name: '9: below the trust minimum on either side, a raw-ratio rise fires',
      snapshot: {audited: 16, classes: {'holistic/overclaimed-guarantee': 4}},
    },
    {
      expected: [],
      live: {
        audited: 32,
        candidates: [['holistic/overclaimed-guarantee', 6]],
      },
      name: '9: below the trust minimum on either side, a raw-ratio refusal holds',
      snapshot: {audited: 16, classes: {'holistic/overclaimed-guarantee': 4}},
    },
    {
      expected: risingTrigger('holistic/overclaimed-guarantee'),
      live: {
        audited: 400,
        candidates: [['holistic/overclaimed-guarantee', 13]],
      },
      name: '9: a trusted live side against an untrusted snapshot falls back to the raw ratio',
      snapshot: {audited: 19, classes: {'holistic/overclaimed-guarantee': 10}},
    },
    {
      expected: [],
      live: {
        audited: 800,
        candidates: [['holistic/n-plus-one', 4]],
        unclassified: 4,
      },
      name: '10: an inventory-only class and unclassified both present in the snapshot are judged as a rise, and both miss the floor',
      snapshot: {
        audited: 400,
        classes: {'holistic/n-plus-one': 2},
        unclassified: 2,
      },
    },
    {
      expected: [],
      live: {audited: 400, candidates: [['holistic/stale-figure', 3]]},
      name: '11: a class present in the snapshot as a live candidate below the floor never rises',
      snapshot: {audited: 400, classes: {'holistic/stale-figure': 2}},
    },
  ] as {
    expected: unknown[];
    live: Parameters<typeof makeLive>[0];
    name: string;
    snapshot: Parameters<typeof makeSnapshot>[0];
  }[])('$name', ({expected, live, snapshot}) => {
    expect(
      evaluateTriggers({live: makeLive(live), snapshot: makeSnapshot(snapshot)})
    ).toEqual(expected);
  });

  test('6: rising_unclassified rules', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {},
      unclassified: 120,
    });

    const risen = evaluateTriggers({
      live: makeLive({audited: 400, candidates: [], unclassified: 150}),
      snapshot,
    });
    expect(risen).toEqual([{type: 'rising_unclassified'}]);

    const nullBaseline = makeSnapshot({
      audited: 400,
      classes: {},
      unclassified: null,
    });
    const fromNullBaseline = evaluateTriggers({
      live: makeLive({audited: 400, candidates: [], unclassified: 10}),
      snapshot: nullBaseline,
    });
    expect(fromNullBaseline).toEqual([{type: 'rising_unclassified'}]);

    const liveSignalNull = evaluateTriggers({
      live: makeLive({audited: 400, candidates: [], unclassified: null}),
      snapshot,
    });
    expect(liveSignalNull).toEqual([]);
  });

  test('7: schema_change refuses every other trigger', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {'holistic/overclaimed-guarantee': 40},
      schemaVersion: TALLY_SCHEMA_VERSION + 1,
    });

    const result = evaluateTriggers({
      live: makeLive({
        audited: 400,
        candidates: [
          ['holistic/overclaimed-guarantee', 50],
          ['holistic/swallowed-error', 5],
        ],
      }),
      snapshot,
    });

    expect(result).toEqual([{type: 'schema_change'}]);
  });

  test('11a: every rise comparison goes through the one shared isMaterialRise (spy proof)', () => {
    const spy = vi.mocked(isMaterialRise);
    spy.mockClear();

    const snapshot = makeSnapshot({
      audited: 400,
      classes: {'holistic/overclaimed-guarantee': 40},
    });
    const live = makeLive({
      audited: 400,
      candidates: [['holistic/overclaimed-guarantee', 50]],
    });

    const risen = evaluateTriggers({live, snapshot});
    expect(risen).toEqual([
      {finding_class: 'holistic/overclaimed-guarantee', type: 'rising_class'},
    ]);
    expect(spy).toHaveBeenCalledWith({
      baseAuditedPrCount: 400,
      baseCount: 40,
      liveAuditedPrCount: 400,
      liveCount: 50,
    });

    // Refusal proof: forcing the spy's next answer to false must flip the
    // result to [], proving the trigger's own logic never reimplements the
    // ratio inline (an inline reimplementation would ignore this mock).
    spy.mockReturnValueOnce(false);
    const refused = evaluateTriggers({live, snapshot});
    expect(refused).toEqual([]);
  });
});
