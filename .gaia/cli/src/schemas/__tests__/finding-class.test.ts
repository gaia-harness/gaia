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

describe('schemas/finding-class', () => {
  describe('oracle buckets (open id space after the prefix)', () => {
    test.each([
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
    ])('accepts a well-formed oracle id: %s', (value) => {
      expect(FindingClassSchema.safeParse(value).success).toBe(true);
      expect(isValidFindingClass(value)).toBe(true);
    });

    test('rejects an oracle prefix with an empty slug', () => {
      expect(FindingClassSchema.safeParse('react-doctor/').success).toBe(false);
      expect(isValidFindingClass('axe/')).toBe(false);
    });

    test.each([
      'cve/GHSA[31m-red',
      'axe/color-contrast\nforged line',
      'knip/exports\r',
      'axe/color contrast',
      'cve/<script>',
      'knip/`exports`',
      'axe/-leading-dash',
      'react-doctor/trailing/',
      'react-doctor//double-slash',
      `axe/${'a'.repeat(129)}`,
    ])('rejects an oracle slug outside the safe id shape: %j', (value) => {
      expect(FindingClassSchema.safeParse(value).success).toBe(false);
      expect(isValidFindingClass(value)).toBe(false);
      expect(isOracleFindingClass(value)).toBe(true);
    });

    test('accepts an oracle slug at the length bound', () => {
      expect(isValidFindingClass(`axe/${'a'.repeat(128)}`)).toBe(true);
    });
  });

  describe('closed holistic/rule buckets (controlled vocabulary)', () => {
    test.each(HOLISTIC_FINDING_CLASSES)(
      'accepts seeded holistic member: %s',
      (value) => {
        expect(FindingClassSchema.safeParse(value).success).toBe(true);
      }
    );

    test.each(RULE_FINDING_CLASSES)(
      'accepts seeded rule member: %s',
      (value) => {
        expect(FindingClassSchema.safeParse(value).success).toBe(true);
      }
    );

    test.each(WORKFLOW_FINDING_CLASSES)(
      'accepts seeded workflow member: %s',
      (value) => {
        expect(FindingClassSchema.safeParse(value).success).toBe(true);
      }
    );

    test('rejects an unseeded holistic member (closed bucket)', () => {
      expect(
        FindingClassSchema.safeParse('holistic/something-made-up').success
      ).toBe(false);
      expect(isValidFindingClass('holistic/something-made-up')).toBe(false);
    });

    test.each(MAINTAINER_SURFACE_MEMBERS.flatMap(([, misses]) => misses))(
      'rejects a near-miss spelling of each seeded maintainer-surface member: %s',
      (value) => {
        expect(FindingClassSchema.safeParse(value).success).toBe(false);
        expect(isValidFindingClass(value)).toBe(false);
      }
    );

    test('rejects an unseeded rule member (closed bucket)', () => {
      expect(
        FindingClassSchema.safeParse('rule/totally-invented').success
      ).toBe(false);
    });

    test('rejects an unseeded workflow member (closed bucket)', () => {
      expect(FindingClassSchema.safeParse('workflow/made-up').success).toBe(
        false
      );
      expect(isValidFindingClass('workflow/made-up')).toBe(false);
    });

    test('rejects an unseeded prose member (closed bucket)', () => {
      expect(FindingClassSchema.safeParse('prose/made-up').success).toBe(false);
      expect(isValidFindingClass('prose/made-up')).toBe(false);
    });
  });

  describe('free-text drift', () => {
    test.each(['just free text', '', 'no-prefix-slug', 'unknown/whatever'])(
      'rejects: %j',
      (value) => {
        expect(FindingClassSchema.safeParse(value).success).toBe(false);
        expect(isValidFindingClass(value)).toBe(false);
      }
    );
  });

  describe('isOracleFindingClass (codify-tally is_oracle source)', () => {
    test.each([
      'react-doctor/no-generic-handler-names',
      'axe/color-contrast',
      'knip/exports',
      'cve/1098765',
    ])('true for an oracle-prefixed class: %s', (value) => {
      expect(isOracleFindingClass(value)).toBe(true);
    });

    test.each([
      'holistic/hardcoded-string',
      'rule/switch-statement',
      'workflow/unpinned-action',
      'prose/excessive-length',
      'not-a-real-prefix/x',
      '',
    ])('false for a non-oracle class: %j', (value) => {
      expect(isOracleFindingClass(value)).toBe(false);
    });
  });

  describe('out-of-scope dedup-key fallback', () => {
    test('has the expected value', () => {
      expect(OUT_OF_SCOPE_FALLBACK_FINDING_CLASS).toBe('holistic/unclassified');
    });

    test('is NOT a valid finding_class (dedup-key fallback only)', () => {
      expect(isValidFindingClass(OUT_OF_SCOPE_FALLBACK_FINDING_CLASS)).toBe(
        false
      );
      expect(
        FindingClassSchema.safeParse(OUT_OF_SCOPE_FALLBACK_FINDING_CLASS)
          .success
      ).toBe(false);
    });
  });

  describe('project vocabulary (.gaia/finding-classes.json)', () => {
    const vocabulary: FindingClassVocabulary = {
      classes: ['holistic/missing-tenant-scope', 'billing/double-charge'],
      oracle_prefixes: ['semgrep'],
    };

    test.each(['holistic/missing-tenant-scope', 'billing/double-charge'])(
      'accepts a project class only with the vocabulary: %s',
      (value) => {
        expect(isValidFindingClass(value)).toBe(false);
        expect(isValidFindingClass(value, vocabulary)).toBe(true);
      }
    );

    test('accepts any safe id after a project oracle prefix and reads it as oracle', () => {
      expect(isValidFindingClass('semgrep/python.lang.eval', vocabulary)).toBe(
        true
      );
      expect(isOracleFindingClass('semgrep/python.lang.eval', vocabulary)).toBe(
        true
      );
      expect(isOracleFindingClass('semgrep/python.lang.eval')).toBe(false);
      expect(isValidFindingClass('semgrep/has space', vocabulary)).toBe(false);
    });

    test('still rejects the fallback and unlisted classes', () => {
      expect(
        isValidFindingClass(OUT_OF_SCOPE_FALLBACK_FINDING_CLASS, vocabulary)
      ).toBe(false);
      expect(isValidFindingClass('billing/refund-race', vocabulary)).toBe(
        false
      );
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

    test('a missing file is the empty vocabulary, silently', () => {
      expect(readProjectFindingClasses(root)).toEqual(
        EMPTY_FINDING_CLASS_VOCABULARY
      );
      expect(errors).toEqual([]);
    });

    test('reads classes and oracle prefixes, ignoring $comment', () => {
      writeVocabulary(
        JSON.stringify({
          $comment: 'project classes',
          classes: ['billing/double-charge'],
          oracle_prefixes: ['semgrep'],
        })
      );

      expect(readProjectFindingClasses(root)).toEqual({
        classes: ['billing/double-charge'],
        oracle_prefixes: ['semgrep'],
      });
      expect(errors).toEqual([]);
    });

    test.each([
      ['invalid JSON', '{'],
      [
        'a non-kebab class',
        JSON.stringify({classes: ['Billing/Double'], oracle_prefixes: []}),
      ],
      [
        'a class with no prefix',
        JSON.stringify({classes: ['double-charge'], oracle_prefixes: []}),
      ],
      [
        'the fallback class',
        JSON.stringify({
          classes: ['holistic/unclassified'],
          oracle_prefixes: [],
        }),
      ],
      [
        'a class under a built-in oracle prefix',
        JSON.stringify({classes: ['axe/custom'], oracle_prefixes: []}),
      ],
      [
        'a built-in prefix as an oracle prefix',
        JSON.stringify({classes: [], oracle_prefixes: ['holistic']}),
      ],
      [
        'a non-kebab oracle prefix',
        JSON.stringify({classes: [], oracle_prefixes: ['Semgrep']}),
      ],
      ['a missing key', JSON.stringify({classes: []})],
    ])(
      'reports %s as a structured error and falls back to empty',
      (_label, content) => {
        writeVocabulary(content);

        expect(readProjectFindingClasses(root)).toEqual(
          EMPTY_FINDING_CLASS_VOCABULARY
        );
        expect(errors).toHaveLength(1);
        expect(JSON.parse(errors[0] ?? '')).toMatchObject({
          code: 'malformed_finding_classes',
        });
      }
    );
  });
});
