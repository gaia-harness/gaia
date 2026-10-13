import {describe, expect, test, vi} from 'vitest';
import {isValidFindingClass} from '../../schemas/finding-class.js';
import {computeTally, windowClasses} from '../compute-tally.js';
import type {TallyPrRecord} from '../compute-tally.js';

const pr = (
  prNumber: number,
  findings: TallyPrRecord['findings']
): TallyPrRecord => ({findings, pr_number: prNumber});

const noCover = (): boolean => false;
const noSuppress = (): boolean => false;

// `findings` distinct classless-fallback PRs, numbered 1..findings.
const fallbackWindow = (findings: number): TallyPrRecord[] =>
  Array.from({length: findings}, (_unused, index) =>
    pr(index + 1, [
      {
        area_tags: [],
        finding_class: 'holistic/unclassified',
        severity: 'major',
      },
    ])
  );

describe('computeTally', () => {
  test('surfaces a class seen on 3 distinct PRs at major severity', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(1201, [
          {
            area_tags: ['app/components'],
            finding_class: 'react-doctor/no-generic-handler-names',
            severity: 'major',
          },
        ]),
        pr(1188, [
          {
            area_tags: ['app/components'],
            finding_class: 'react-doctor/no-generic-handler-names',
            severity: 'major',
          },
        ]),
        pr(1175, [
          {
            area_tags: ['app/hooks'],
            finding_class: 'react-doctor/no-generic-handler-names',
            severity: 'major',
          },
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(1);
    expect(result.window_days).toBe(90);

    expect(result.candidates[0]).toMatchObject({
      area_tags: ['app/components', 'app/hooks'],
      distinct_pr_count: 3,
      finding_class: 'react-doctor/no-generic-handler-names',
      is_oracle: true,
      pr_numbers: [1201, 1188, 1175],
      severity_max: 'major',
    });
  });

  test('sets is_oracle false for a closed-vocabulary (non-oracle) class', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'major',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidates[0]?.is_oracle).toBe(false);
  });

  test('does not surface a class on only 2 distinct PRs', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(2, [
          {area_tags: [], finding_class: 'knip/exports', severity: 'major'},
        ]),
        pr(1, [
          {area_tags: [], finding_class: 'knip/exports', severity: 'major'},
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
  });

  test('does not surface a class repeated 3 times within ONE PR', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(1, [
          {area_tags: [], finding_class: 'knip/exports', severity: 'major'},
          {area_tags: [], finding_class: 'knip/exports', severity: 'major'},
          {area_tags: [], finding_class: 'knip/exports', severity: 'major'},
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
  });

  test('UAT-001: a minor-only recurring class is a candidate with severity_max minor', () => {
    const minorOnly = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'holistic/hardcoded-string',
            severity: 'minor',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });
    expect(minorOnly.candidate_count).toBe(1);
    expect(minorOnly.candidates[0]).toMatchObject({
      distinct_pr_count: 3,
      severity_max: 'minor',
    });
    expect(minorOnly.unclassified).toBeNull();

    const atMajor = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'holistic/hardcoded-string',
            severity: 'major',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });
    expect(atMajor.candidate_count).toBe(1);
    expect(atMajor.candidates[0]?.severity_max).toBe('major');
  });

  test('combines CI-run and local-run findings for the same class across distinct PRs', () => {
    // Each PR contributes one comment block (CI or local); the core only sees a
    // per-PR finding list, so auditor location never changes eligibility.
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(10, [
          {
            area_tags: ['app'],
            finding_class: 'rule/switch-statement',
            severity: 'major',
          },
        ]),
        pr(11, [
          {
            area_tags: ['app'],
            finding_class: 'rule/switch-statement',
            severity: 'critical',
          },
        ]),
        pr(12, [
          {
            area_tags: ['app'],
            finding_class: 'rule/switch-statement',
            severity: 'major',
          },
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(1);
    expect(result.candidates[0]?.severity_max).toBe('critical');
  });

  test('collapses two same-class findings in one PR to a single distinct-PR count', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [30, 20, 10].map((n) =>
        pr(n, [
          {
            area_tags: ['app/routes'],
            finding_class: 'holistic/missing-auth-check',
            severity: 'critical',
          },
          {
            area_tags: ['app/pages'],
            finding_class: 'holistic/missing-auth-check',
            severity: 'major',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidates[0]).toMatchObject({
      area_tags: ['app/routes', 'app/pages'],
      distinct_pr_count: 3,
      severity_max: 'critical',
    });
  });

  test('ignores class-less / invalid findings entirely', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {area_tags: [], finding_class: '', severity: 'critical'},
          {
            area_tags: [],
            finding_class: 'not-a-real-prefix/x',
            severity: 'critical',
          },
          {
            area_tags: [],
            finding_class: 'holistic/something-made-up',
            severity: 'critical',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
  });

  test('UAT-002: an unseeded holistic slug is dropped, not a candidate nor unclassified', () => {
    expect(isValidFindingClass('holistic/arbitrary-slug')).toBe(false);

    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'holistic/arbitrary-slug',
            severity: 'critical',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
    expect(result.unclassified).toBeNull();
  });

  test('UAT-003: a classless recurring finding surfaces as the distinct unclassified signal, not a candidate', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(1, [
          {
            area_tags: ['app/routes'],
            finding_class: 'holistic/unclassified',
            severity: 'major',
          },
          // A second, distinct classless finding in the SAME PR must still
          // collapse to a single distinct-PR increment (cardinality one).
          {
            area_tags: ['app/services'],
            finding_class: 'holistic/unclassified',
            severity: 'critical',
          },
        ]),
        pr(2, [
          {
            area_tags: [],
            finding_class: 'holistic/unclassified',
            severity: 'minor',
          },
        ]),
        pr(3, [
          {
            area_tags: [],
            finding_class: 'holistic/unclassified',
            severity: 'major',
          },
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
    expect(
      result.candidates.every(
        (c) => c.finding_class !== 'holistic/unclassified'
      )
    ).toBe(true);
    expect(result.unclassified).not.toBeNull();
    expect(result.unclassified?.distinct_pr_count).toBe(3);
    expect(result.unclassified?.severity_max).toBe('critical');
    expect(result.unclassified?.area_tags).toEqual([
      'app/routes',
      'app/services',
    ]);
  });

  test('UAT-007: a classless finding on only 2 distinct PRs leaves unclassified null', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'holistic/unclassified',
            severity: 'major',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.unclassified).toBeNull();
  });

  test('windowClasses includes the classless unclassified bucket once it recurs at threshold', () => {
    const prs = [3, 2, 1].map((n) =>
      pr(n, [
        {
          area_tags: [],
          finding_class: 'holistic/unclassified',
          severity: 'major',
        },
      ])
    );

    expect(windowClasses(prs)).toEqual(['holistic/unclassified']);
  });

  test('windowClasses drops the classless unclassified bucket below threshold, so the prune releases a stale baseline', () => {
    const prs = [2, 1].map((n) =>
      pr(n, [
        {
          area_tags: [],
          finding_class: 'holistic/unclassified',
          severity: 'major',
        },
      ])
    );

    expect(windowClasses(prs)).toEqual([]);
  });

  test('Directive #1: severity_max is a running max across PRs (minor then critical -> critical)', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(1, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'minor',
          },
        ]),
        pr(2, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'critical',
          },
        ]),
        pr(3, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'minor',
          },
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidates[0]?.severity_max).toBe('critical');
  });

  test('Directive #1: severity_max is never downgraded (major then minor -> major)', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(1, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'major',
          },
        ]),
        pr(2, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'minor',
          },
        ]),
        pr(3, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'minor',
          },
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidates[0]?.severity_max).toBe('major');
  });

  test('Directive #5: an oracle-prefixed class at minor severity is still a candidate', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'knip/exports',
            severity: 'minor',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidates[0]).toMatchObject({
      is_oracle: true,
      severity_max: 'minor',
    });
  });

  test('a recorded recurring class counts whether or not a later PR fixed it (the tally has no found-and-fixed notion)', () => {
    // The tally only sees whatever findings were recorded in the block for
    // each PR; it has no concept of "found-and-healed". A class recorded as
    // recurring produces a candidate even though the tally cannot know (and
    // does not care) whether a later PR fixed the underlying issue.
    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'holistic/swallowed-error',
            severity: 'major',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(1);
    expect(result.candidates[0]?.finding_class).toBe(
      'holistic/swallowed-error'
    );
  });

  test('drops a class a promoted rule already covers', () => {
    const result = computeTally({
      coveredClass: (c) => c === 'rule/switch-statement',
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'major',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
  });

  test('drops a class the ledger reports suppressed and passes the live PR count and audited-PR denominator', () => {
    const seen: [number, number][] = [];
    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'axe/color-contrast',
            severity: 'critical',
          },
        ])
      ),
      suppressedClass: (_c, currentPrCount, currentAuditedPrCount) => {
        seen.push([currentPrCount, currentAuditedPrCount]);

        return true;
      },
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
    expect(seen).toContainEqual([3, 3]);
  });

  test('windowClasses returns classes with >= threshold recurrence regardless of suppression', () => {
    const prs = [
      ...[3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'axe/color-contrast',
            severity: 'major',
          },
        ])
      ),
      pr(99, [{area_tags: [], finding_class: 'knip/types', severity: 'major'}]),
    ];

    expect(windowClasses(prs)).toEqual(['axe/color-contrast']);
  });

  const fallbackPrs = [3, 2, 1].map((n) =>
    pr(n, [
      {
        area_tags: [],
        finding_class: 'holistic/unclassified',
        severity: 'major',
      },
    ])
  );

  test('the fallback branch is suppressible', () => {
    const suppressed = computeTally({
      coveredClass: noCover,
      prs: fallbackPrs,
      suppressedClass: () => true,
      windowDays: 90,
    });

    expect(suppressed.unclassified).toBeNull();

    const notSuppressed = computeTally({
      coveredClass: noCover,
      prs: fallbackPrs,
      suppressedClass: () => false,
      windowDays: 90,
    });

    expect(notSuppressed.unclassified).not.toBeNull();
  });

  test('the suppression predicate receives the fallback class, its own distinct-PR count, and the audited-PR denominator', () => {
    const seen: [string, number, number][] = [];

    computeTally({
      coveredClass: noCover,
      prs: fallbackPrs,
      suppressedClass: (
        findingClass,
        currentPrCount,
        currentAuditedPrCount
      ) => {
        seen.push([findingClass, currentPrCount, currentAuditedPrCount]);

        return false;
      },
      windowDays: 90,
    });

    expect(seen).toEqual([['holistic/unclassified', 3, 3]]);
  });

  test('the fallback is still not a candidate under suppression or without it', () => {
    for (const suppressedClass of [(): boolean => true, (): boolean => false]) {
      const result = computeTally({
        coveredClass: noCover,
        prs: fallbackPrs,
        suppressedClass,
        windowDays: 90,
      });

      expect(
        result.candidates.some(
          (c) => c.finding_class === 'holistic/unclassified'
        )
      ).toBe(false);
    }
  });

  test('class_inventory holds a below-threshold class without it becoming a candidate; a covered or suppressed class holds neither; suppressedClass is queried only at threshold, with (class, count, prs.length)', () => {
    const calls: [string, number, number][] = [];
    const suppressedClass = vi.fn(
      (
        findingClass: string,
        currentPrCount: number,
        currentAuditedPrCount: number
      ) => {
        calls.push([findingClass, currentPrCount, currentAuditedPrCount]);

        return findingClass === 'axe/color-contrast';
      }
    );

    const prs = [
      pr(101, [
        {
          area_tags: [],
          finding_class: 'holistic/stale-figure',
          severity: 'major',
        },
      ]),
      pr(102, [
        {
          area_tags: [],
          finding_class: 'holistic/stale-figure',
          severity: 'major',
        },
      ]),
      ...[201, 202, 203].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'major',
          },
        ])
      ),
      ...[301, 302, 303].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'axe/color-contrast',
            severity: 'major',
          },
        ])
      ),
    ];

    const result = computeTally({
      coveredClass: (c) => c === 'rule/switch-statement',
      prs,
      suppressedClass,
      windowDays: 90,
    });

    expect(result.candidates).toEqual([]);
    expect(result.class_inventory).toEqual([
      {distinct_pr_count: 2, finding_class: 'holistic/stale-figure'},
    ]);
    expect(calls).toContainEqual(['rule/switch-statement', 3, 8]);
    expect(calls).toContainEqual(['axe/color-contrast', 3, 8]);
    expect(
      calls.some(([findingClass]) => findingClass === 'holistic/stale-figure')
    ).toBe(false);
  });

  test('unclassified_window_count: below-threshold count, absent, suppressed-at-threshold, and unsuppressed-at-threshold', () => {
    expect(
      computeTally({
        coveredClass: noCover,
        prs: fallbackWindow(2),
        suppressedClass: noSuppress,
        windowDays: 90,
      }).unclassified_window_count
    ).toBe(2);

    expect(
      computeTally({
        coveredClass: noCover,
        prs: [],
        suppressedClass: noSuppress,
        windowDays: 90,
      }).unclassified_window_count
    ).toBeNull();

    const suppressed = computeTally({
      coveredClass: noCover,
      prs: fallbackWindow(5),
      suppressedClass: () => true,
      windowDays: 90,
    });
    expect(suppressed.unclassified_window_count).toBeNull();
    expect(suppressed.unclassified).toBeNull();

    const unsuppressed = computeTally({
      coveredClass: noCover,
      prs: fallbackWindow(5),
      suppressedClass: () => false,
      windowDays: 90,
    });
    expect(unsuppressed.unclassified_window_count).toBe(5);
  });

  test('audited_pr_count equals prs.length, including a PR whose record has an empty findings array', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(1, [
          {
            area_tags: [],
            finding_class: 'holistic/stale-figure',
            severity: 'major',
          },
        ]),
        pr(2, []),
        pr(3, []),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.audited_pr_count).toBe(3);
  });
});
