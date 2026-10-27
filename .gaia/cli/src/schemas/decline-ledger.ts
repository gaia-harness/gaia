/**
 * Schema and reader for the legacy per-clone decline ledger at
 * `.gaia/local/codify/declines.json`. Current GAIA reads it and never writes
 * it: committed declines live in `.gaia/codify-declines/`. An entry is judged
 * by its own `declined_at` and lapses with the tally window; a malformed
 * file suppresses nothing, and the `read*` result carries
 * `status: 'malformed'` so the caller can report it.
 *
 * The schema is version 2 and every entry carries both
 * `declined_at_audited_pr_count` and `tally_schema_version`, because a raw
 * count with no denominator cannot be compared to a live share honestly.
 */
import {z} from 'zod';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {summarizeZodError} from './zod-error.js';

export const declineLedgerPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'local', 'codify', 'declines.json');

export const DeclineEntrySchema = z.object({
  declined_at: z.iso.datetime(),
  declined_at_audited_pr_count: z.number().int().nonnegative(),
  declined_at_pr_count: z.number().int().nonnegative(),
  finding_class: z.string().min(1),
  tally_schema_version: z.number().int().nonnegative(),
});

export type DeclineEntry = z.infer<typeof DeclineEntrySchema>;

// `version` is declared first so JSON serialization emits it first, matching
// the frozen ledger shape (`{"version":2,"declines":[]}`).
export const DeclineLedgerSchema = z.object({
  version: z.literal(2),
  // eslint-disable-next-line perfectionist/sort-objects -- serialization order load-bearing, version-first
  declines: z.array(DeclineEntrySchema),
});

export type DeclineLedger = z.infer<typeof DeclineLedgerSchema>;

export type ReadDeclineLedgerResult =
  | {error: string; status: 'malformed'}
  | {ledger: DeclineLedger; status: 'ok'}
  | {status: 'missing'};

export const readDeclineLedger = (
  repoRoot: string
): ReadDeclineLedgerResult => {
  const filePath = declineLedgerPath(repoRoot);

  if (!existsSync(filePath)) return {status: 'missing'};

  let raw: string;

  try {
    raw = readFileSync(filePath, 'utf8');
  } catch (error) {
    return {
      error: `${filePath}: ${error instanceof Error ? error.message : String(error)}`,
      status: 'malformed',
    };
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    return {
      error: `${filePath}: invalid JSON: ${error instanceof Error ? error.message : String(error)}`,
      status: 'malformed',
    };
  }

  const result = DeclineLedgerSchema.safeParse(parsed);

  if (!result.success) {
    return {
      error: summarizeZodError(filePath, result.error),
      status: 'malformed',
    };
  }

  return {ledger: result.data, status: 'ok'};
};
