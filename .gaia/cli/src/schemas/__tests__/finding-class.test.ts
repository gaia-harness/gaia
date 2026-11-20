import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  EMPTY_FINDING_CLASS_VOCABULARY,
  FindingClassSchema,
  HOLISTIC_FINDING_CLASSES,
  isOracleFindingClass,
  isValidFindingClass,
  OUT_OF_SCOPE_FALLBACK_FINDING_CLASS,
  readProjectFindingClasses,
  RULE_FINDING_CLASSES,
  WORKFLOW_FINDING_CLASSES,
} from '../finding-class.js';
import type {
  FindingClassVocabulary,
  HolisticFindingClass,
} from '../finding-class.js';

/**
 * Near-miss spellings per maintainer-surface member, the shapes a writer
 * reaches for when the real slug is nearly right. Held as pairs rather than a
 * flat list so one table feeds the rejection cases below.
 */
const MAINTAINER_SURFACE_MEMBERS: readonly (readonly [
  HolisticFindingClass,
  readonly string[],
])[] = [
  [
    'holistic/hollow-assertion',
    ['holistic/hollow-assertions', 'holistic/hollow_assertion'],
  ],
  [
    'holistic/uncoupled-restatement',
    ['holistic/uncoupled-restatements', 'holistic/uncoupled-restatement-prose'],
  ],
  ['holistic/stale-figure', ['holistic/stale-figures', 'holistic/stale-count']],
  [
    'holistic/unarmed-guard',
    ['holistic/unarmed-guards', 'holistic/unarmed-check'],
  ],
  [
    'holistic/fail-open-discovery',
    ['holistic/fail-open-discoveries', 'holistic/failopen-discovery'],
  ],
  [
    'holistic/partial-cause-reporting',
    ['holistic/partial-cause-report', 'holistic/partial-cause-reporting-2'],
  ],
  [
    'holistic/dangling-reference',
    ['holistic/dangling-references', 'holistic/dangling-ref'],
  ],
  [
    'holistic/drifting-duplicate',
    ['holistic/drifting-duplicates', 'holistic/drifted-duplicate'],
  ],
  [
    'holistic/ambient-context-resolution',
    ['holistic/ambient-context-resolutions', 'holistic/ambient-context'],
  ],
  [
    'holistic/shared-state-collision',
    ['holistic/shared-state-collisions', 'holistic/shared-state-race'],
  ],
  [
    'holistic/unbounded-invocation',
    ['holistic/unbounded-invocations', 'holistic/unbounded-call'],
  ],
  [
    'holistic/overclaimed-guarantee',
    ['holistic/overclaimed-guarantees', 'holistic/overclaim'],
  ],
  [
    'holistic/incomplete-enumeration',
    ['holistic/incomplete-enumerations', 'holistic/partial-enumeration'],
  ],
  [
    'holistic/repeated-round-trip',
    ['holistic/repeated-round-trips', 'holistic/repeated-roundtrip'],
  ],
];

const validOracleIds = [
  'react-doctor/no-generic-handler-names',
  'axe/color-contrast',
  'knip/exports',
  'knip/types',
  'knip/dependencies',
  'knip/enumMembers',
  'axe/landmark-one-main',
  'cve/1098765',
  'cve/GHSA-9wv6-86v2-598j',
  'cve/CVE-2024-12345',
  'react-doctor/jsx-a11y/alt-text',
  'react-doctor/react.no-danger_v2',
];

const unsafeOracleSlugs = [
  'cve/GHSA[31m-red',
  'axe/color-contrast\nforged line',
  'knip/exports\r',
  'axe/color contrast',
  'cve/<script>',
  'knip/`exports`',
  'axe/-leading-dash',
  'react-doctor/trailing/',
  'react-doctor//double-slash',
  `axe/${'a'.repeat(129)}`,
];

type ClassCase = {title: string; valid: boolean; value: string};

const accepted = (title: string, values: readonly string[]): ClassCase[] =>
  values.map((value) => ({title: `${title}: ${value}`, valid: true, value}));

const rejected = (title: string, values: readonly string[]): ClassCase[] =>
  values.map((value) => ({
    title: `${title}: ${JSON.stringify(value)}`,
    valid: false,
    value,
  }));

describe('schemas/finding-class', () => {
  test.each([
    ...accepted('accepts a well-formed oracle id', validOracleIds),
    {
      title: 'rejects an oracle prefix with an empty slug: react-doctor/',
      valid: false,
      value: 'react-doctor/',
    },
    {
      title: 'rejects an oracle prefix with an empty slug: axe/',
      valid: false,
      value: 'axe/',
    },
    ...rejected(
      'rejects an oracle slug outside the safe id shape',
      unsafeOracleSlugs
    ),
    {
      title: 'accepts an oracle slug at the length bound',
      valid: true,
      value: `axe/${'a'.repeat(128)}`,
    },
  ])('oracle buckets: $title', ({valid, value}) => {
    expect(FindingClassSchema.safeParse(value).success).toBe(valid);
    expect(isValidFindingClass(value)).toBe(valid);
    expect(isOracleFindingClass(value)).toBe(true);
  });

  test.each([
    ...accepted('accepts seeded holistic member', HOLISTIC_FINDING_CLASSES),
    ...accepted('accepts seeded rule member', RULE_FINDING_CLASSES),
    ...accepted('accepts seeded workflow member', WORKFLOW_FINDING_CLASSES),
    {
      title: 'rejects an unseeded holistic member (closed bucket)',
      valid: false,
      value: 'holistic/something-made-up',
    },
    ...rejected(
      'rejects a near-miss spelling of each seeded maintainer-surface member',
      MAINTAINER_SURFACE_MEMBERS.flatMap(([, misses]) => misses)
    ),
    {
      title: 'rejects an unseeded rule member (closed bucket)',
      valid: false,
      value: 'rule/totally-invented',
    },
    {
      title: 'rejects an unseeded workflow member (closed bucket)',
      valid: false,
      value: 'workflow/made-up',
    },
    {
      title: 'rejects an unseeded prose member (closed bucket)',
      valid: false,
      value: 'prose/made-up',
    },
    ...rejected('rejects', [
      'just free text',
      '',
      'no-prefix-slug',
      'unknown/whatever',
    ]),
  ])('closed buckets: $title', ({valid, value}) => {
    expect(FindingClassSchema.safeParse(value).success).toBe(valid);
    expect(isValidFindingClass(value)).toBe(valid);
  });

  test.each([
    ...[
      'react-doctor/no-generic-handler-names',
      'axe/color-contrast',
      'knip/exports',
      'cve/1098765',
    ].map((value) => ({
      oracle: true,
      title: `true for an oracle-prefixed class: ${value}`,
      value,
    })),
    ...[
      'holistic/hardcoded-string',
      'rule/switch-statement',
      'workflow/unpinned-action',
      'prose/excessive-length',
      'not-a-real-prefix/x',
      '',
    ].map((value) => ({
      oracle: false,
      title: `false for a non-oracle class: ${JSON.stringify(value)}`,
      value,
    })),
  ])(
    'isOracleFindingClass (codify-tally is_oracle source): $title',
    ({oracle, value}) => {
      expect(isOracleFindingClass(value)).toBe(oracle);
    }
  );

  test.each([
    {
      actual: () => OUT_OF_SCOPE_FALLBACK_FINDING_CLASS,
      expected: 'holistic/unclassified',
      name: 'has the expected value',
    },
    {
      actual: () => [
        isValidFindingClass(OUT_OF_SCOPE_FALLBACK_FINDING_CLASS),
        FindingClassSchema.safeParse(OUT_OF_SCOPE_FALLBACK_FINDING_CLASS)
          .success,
      ],
      expected: [false, false],
      name: 'is NOT a valid finding_class (dedup-key fallback only)',
    },
  ])('out-of-scope dedup-key fallback: $name', ({actual, expected}) => {
    expect(actual()).toEqual(expected);
  });

  describe('project vocabulary (.gaia/finding-classes.json)', () => {
    const vocabulary: FindingClassVocabulary = {
      classes: ['holistic/missing-tenant-scope', 'billing/double-charge'],
      oracle_prefixes: ['semgrep'],
    };

    test.each([
      {
        name: 'accepts a project class only with the vocabulary: holistic/missing-tenant-scope',
        oracleWith: false,
        validWith: true,
        validWithout: false,
        value: 'holistic/missing-tenant-scope',
      },
      {
        name: 'accepts a project class only with the vocabulary: billing/double-charge',
        oracleWith: false,
        validWith: true,
        validWithout: false,
        value: 'billing/double-charge',
      },
      {
        name: 'accepts any safe id after a project oracle prefix and reads it as oracle',
        oracleWith: true,
        validWith: true,
        validWithout: false,
        value: 'semgrep/python.lang.eval',
      },
      {
        name: 'rejects an unsafe id after a project oracle prefix',
        oracleWith: true,
        validWith: false,
        validWithout: false,
        value: 'semgrep/has space',
      },
      {
        name: 'still rejects the fallback and unlisted classes: fallback',
        oracleWith: false,
        validWith: false,
        validWithout: false,
        value: OUT_OF_SCOPE_FALLBACK_FINDING_CLASS,
      },
      {
        name: 'still rejects the fallback and unlisted classes: unlisted',
        oracleWith: false,
        validWith: false,
        validWithout: false,
        value: 'billing/refund-race',
      },
    ])('$name', ({oracleWith, validWith, validWithout, value}) => {
      expect(isValidFindingClass(value)).toBe(validWithout);
      expect(isValidFindingClass(value, vocabulary)).toBe(validWith);
      expect(isOracleFindingClass(value, vocabulary)).toBe(oracleWith);
      expect(isOracleFindingClass(value)).toBe(false);
    });
  });

  describe('readProjectFindingClasses', () => {
    let root: string;
    let errors: string[];

    const writeVocabulary = (content: string): void => {
      mkdirSync(path.join(root, '.gaia'), {recursive: true});
      writeFileSync(
        path.join(root, '.gaia', 'finding-classes.json'),
        content,
        'utf8'
      );
    };

    beforeEach(() => {
      root = mkdtempSync(path.join(tmpdir(), 'gaia-finding-classes-'));
      errors = [];
      vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
        errors.push(typeof chunk === 'string' ? chunk : String(chunk));

        return true;
      });
    });

    afterEach(() => {
      vi.restoreAllMocks();
      rmSync(root, {force: true, recursive: true});
    });

    const writeVocabularyIfPresent = (content: string | undefined): void => {
      if (content !== undefined) {
        writeVocabulary(content);
      }
    };

    const malformed = ['malformed_finding_classes'];
    const reportsAndFallsBack = (label: string, content: string) => ({
      content,
      errorCodes: malformed,
      expected: EMPTY_FINDING_CLASS_VOCABULARY,
      name: `reports ${label} as a structured error and falls back to empty`,
    });

    test.each([
      {
        content: undefined,
        errorCodes: [],
        expected: EMPTY_FINDING_CLASS_VOCABULARY,
        name: 'a missing file is the empty vocabulary, silently',
      },
      {
        content: JSON.stringify({
          $comment: 'project classes',
          classes: ['billing/double-charge'],
          oracle_prefixes: ['semgrep'],
        }),
        errorCodes: [],
        expected: {
          classes: ['billing/double-charge'],
          oracle_prefixes: ['semgrep'],
        },
        name: 'reads classes and oracle prefixes, ignoring $comment',
      },
      reportsAndFallsBack('invalid JSON', '{'),
      reportsAndFallsBack(
        'a non-kebab class',
        JSON.stringify({classes: ['Billing/Double'], oracle_prefixes: []})
      ),
      reportsAndFallsBack(
        'a class with no prefix',
        JSON.stringify({classes: ['double-charge'], oracle_prefixes: []})
      ),
      reportsAndFallsBack(
        'the fallback class',
        JSON.stringify({
          classes: ['holistic/unclassified'],
          oracle_prefixes: [],
        })
      ),
      reportsAndFallsBack(
        'a class under a built-in oracle prefix',
        JSON.stringify({classes: ['axe/custom'], oracle_prefixes: []})
      ),
      reportsAndFallsBack(
        'a built-in prefix as an oracle prefix',
        JSON.stringify({classes: [], oracle_prefixes: ['holistic']})
      ),
      reportsAndFallsBack(
        'a non-kebab oracle prefix',
        JSON.stringify({classes: [], oracle_prefixes: ['Semgrep']})
      ),
      reportsAndFallsBack('a missing key', JSON.stringify({classes: []})),
    ])('$name', ({content, errorCodes, expected}) => {
      writeVocabularyIfPresent(content);

      expect(readProjectFindingClasses(root)).toEqual(expected);
      expect(
        errors.map((line) => (JSON.parse(line) as {code: string}).code)
      ).toEqual(errorCodes);
    });
  });
});
