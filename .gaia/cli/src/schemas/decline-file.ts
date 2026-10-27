import {z} from 'zod';

/** Repo-relative folder holding one committed JSON file per decline. */
export const DECLINE_STORE_RELATIVE_PATH = '.gaia/codify-declines';

/** Version of the decline-file format, separate from the tally schema version. */
export const DECLINE_FILE_FORMAT_VERSION = 1;

/**
 * One committed decline. Loose so a key added by a later writer does not
 * skip the file; `format_version` is declared first so serialization emits
 * it first.
 */
export const DeclineFileSchema = z.looseObject({
  format_version: z.literal(DECLINE_FILE_FORMAT_VERSION),
  /* eslint-disable perfectionist/sort-objects -- serialization order load-bearing, version-first */
  declined_at: z.iso.datetime(),
  declined_at_audited_pr_count: z.number().int().nonnegative(),
  declined_at_pr_count: z.number().int().nonnegative(),
  finding_class: z.string().min(1),
  tally_schema_version: z.number().int().nonnegative(),
  /* eslint-enable perfectionist/sort-objects */
});

export type DeclineFile = z.infer<typeof DeclineFileSchema>;
