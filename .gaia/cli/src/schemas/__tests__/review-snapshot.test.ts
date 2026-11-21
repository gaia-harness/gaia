import {describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  readReviewSnapshot,
  reviewSnapshotPath,
  ReviewTallyInputSchema,
  snapshotFromTally,
  writeReviewSnapshot,
} from '../review-snapshot.js';
import type {ReviewTallyInput} from '../review-snapshot.js';

const FIXED_NOW = new Date('2026-09-18T10:00:00.000Z');

const FULL_TALLY: ReviewTallyInput = {
  audited_pr_count: 400,
  class_inventory: [
    {distinct_pr_count: 40, finding_class: 'holistic/overclaimed-guarantee'},
    {distinct_pr_count: 10, finding_class: 'holistic/drifting-duplicate'},
    {distinct_pr_count: 2, finding_class: 'holistic/swallowed-error'},
  ],
  gh_ok: true,
  tally_schema_version: 1,
  unclassified_window_count: 120,
  window_days: 90,
};

describe('schemas/review-snapshot', () => {
  describe('snapshotFromTally', () => {
    test.each([
      {
        expected: {
          audited_pr_count: 400,
          classes: {
            'holistic/drifting-duplicate': {
              distinct_pr_count: 10,
              share: 0.025,
            },
            'holistic/overclaimed-guarantee': {
              distinct_pr_count: 40,
              share: 0.1,
            },
            'holistic/swallowed-error': {distinct_pr_count: 2, share: 0.005},
          },
          reviewed_at: FIXED_NOW.toISOString(),
          tally_schema_version: 1,
          unclassified: {distinct_pr_count: 120, share: 0.3},
          version: 1,
          window_days: 90,
        },
        name: 'returns exact shares and full inventory',
        tally: FULL_TALLY,
      },
      {
        expected: {
          audited_pr_count: 0,
          classes: {},
          reviewed_at: FIXED_NOW.toISOString(),
          tally_schema_version: 1,
          unclassified: null,
          version: 1,
          window_days: 90,
        },
        name: 'returns empty classes and null unclassified for a zero-candidate tally',
        tally: {
          audited_pr_count: 0,
          class_inventory: [],
          gh_ok: true,
          tally_schema_version: 1,
          unclassified_window_count: null,
          window_days: 90,
        },
      },
    ])('$name', ({expected, tally}) => {
      expect(snapshotFromTally(tally, FIXED_NOW)).toEqual(expected);
    });
  });

  describe('ReviewTallyInputSchema', () => {
    const without = (key: keyof ReviewTallyInput): Record<string, unknown> =>
      Object.fromEntries(
        Object.entries(FULL_TALLY).filter(([entryKey]) => entryKey !== key)
      );

    test.each([
      {
        input: without('audited_pr_count'),
        name: 'refuses a tally missing audited_pr_count',
      },
      {
        input: without('class_inventory'),
        name: 'refuses a tally missing class_inventory',
      },
      {
        input: {...FULL_TALLY, unclassified_window_count: 0},
        name: 'refuses unclassified_window_count: 0',
      },
      {
        input: {
          candidate_count: 1,
          candidates: [],
          gh_ok: true,
          unclassified: null,
          window_days: 90,
        },
        name: 'refuses a pre-SPEC tally shape',
      },
    ])('$name', ({input}) => {
      expect(ReviewTallyInputSchema.safeParse(input).success).toBe(false);
    });

    test('accepts a tally carrying extra keys', () => {
      expect(
        ReviewTallyInputSchema.safeParse({
          ...FULL_TALLY,
          candidates: [],
          triggers: [],
        }).success
      ).toBe(true);
    });
  });

  describe('read/write round trip', () => {
    let root: string;

    const setup = (): void => {
      root = mkdtempSync(path.join(tmpdir(), 'gaia-review-snapshot-'));
    };

    const cleanup = (): void => {
      rmSync(root, {force: true, recursive: true});
    };

    const writeRaw = (text: string): void => {
      mkdirSync(path.dirname(reviewSnapshotPath(root)), {recursive: true});
      writeFileSync(reviewSnapshotPath(root), text, 'utf8');
    };
    const fullSnapshot = snapshotFromTally(FULL_TALLY, FIXED_NOW);

    test.each([
      {
        expected: {snapshot: fullSnapshot, status: 'ok'},
        name: 'round-trips to status ok with deep-equal content',
        prepare: () => {
          writeReviewSnapshot(root, fullSnapshot);
        },
      },
      {
        expected: {status: 'missing'},
        name: 'returns missing when the file does not exist',
        prepare: () => {},
      },
      {
        expected: {status: 'malformed'},
        name: 'returns malformed for invalid JSON',
        prepare: () => {
          writeRaw('{ not json');
        },
      },
      {
        expected: {status: 'malformed'},
        name: 'returns malformed for valid JSON failing the schema',
        prepare: () => {
          writeRaw(JSON.stringify({...fullSnapshot, classes: 'nope'}));
        },
      },
      {
        expected: {status: 'ok'},
        name: 'writeReviewSnapshot overwrites a pre-existing malformed file unconditionally',
        prepare: () => {
          writeRaw('{"broken":');
          writeReviewSnapshot(root, fullSnapshot);
        },
      },
    ])('$name', ({expected, prepare}) => {
      setup();

      try {
        prepare();

        expect(readReviewSnapshot(root)).toMatchObject(expected);
      } finally {
        cleanup();
      }
    });
  });
});
