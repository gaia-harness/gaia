import type {FieldMergeReport} from './field-verdict.js';

export type BucketName = keyof FieldMergeReport;

export type VerdictRow = {
  /** Undefined means the key is absent from that side. */
  adopter: number | undefined;
  baseline: number | undefined;
  /** Bucket the key lands in, or `none` when it is not reported. */
  expected: 'none' | BucketName;
  latest: number | undefined;
  name: string;
  reason?: 'added' | 'changed';
};

/** Every row of the field-verdict table, with 1 and 2 as the two GAIA values. */
export const VERDICT_ROWS: readonly VerdictRow[] = [
  {
    adopter: 1,
    baseline: 1,
    expected: 'none',
    latest: 1,
    name: 'B == L is a no-op',
  },
  {
    adopter: 2,
    baseline: 1,
    expected: 'alreadyLatest',
    latest: 2,
    name: 'B != L, adopter already at L',
  },
  {
    adopter: 1,
    baseline: 1,
    expected: 'applied',
    latest: 2,
    name: 'B != L, adopter at B',
    reason: 'changed',
  },
  {
    adopter: 3,
    baseline: 1,
    expected: 'conflicts',
    latest: 2,
    name: 'B != L, adopter differs from both',
  },
  {
    adopter: undefined,
    baseline: 1,
    expected: 'keptRemoved',
    latest: 2,
    name: 'B != L, adopter removed the key',
  },
  {
    adopter: undefined,
    baseline: undefined,
    expected: 'applied',
    latest: 2,
    name: 'L only, adopter lacks the key',
    reason: 'added',
  },
  {
    adopter: 2,
    baseline: undefined,
    expected: 'alreadyLatest',
    latest: 2,
    name: 'L only, adopter already at L',
  },
  {
    adopter: 3,
    baseline: undefined,
    expected: 'conflicts',
    latest: 2,
    name: 'L only, adopter holds a different value',
  },
  {
    adopter: 1,
    baseline: 1,
    expected: 'removedUpstream',
    latest: undefined,
    name: 'B only, adopter still has the key',
  },
  {
    adopter: undefined,
    baseline: 1,
    expected: 'none',
    latest: undefined,
    name: 'B only, adopter lacks the key',
  },
];

const BUCKET_NAMES: readonly BucketName[] = [
  'alreadyLatest',
  'applied',
  'conflicts',
  'keptRemoved',
  'removedUpstream',
];

/** The one bucket holding items, or `none`; `many` when more than one does. */
export const occupiedBucket = (
  report: FieldMergeReport
): 'many' | 'none' | BucketName => {
  const occupied = BUCKET_NAMES.filter((name) => report[name].length > 0);

  if (occupied.length === 0) return 'none';

  return occupied.length === 1 ? (occupied[0] ?? 'none') : 'many';
};
