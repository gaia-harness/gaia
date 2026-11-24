import type {Candidate} from './compare.js';

export const CLEAN_LINE = 'value-sets: no duplicate value sets';

export const CANNOT_RUN_PREFIX = 'value-sets: cannot run: ';

/** The `--candidates` output: a JSON array plus a trailing newline. */
export const formatCandidates = (candidates: readonly Candidate[]): string =>
  `${JSON.stringify(candidates, null, 2)}\n`;
