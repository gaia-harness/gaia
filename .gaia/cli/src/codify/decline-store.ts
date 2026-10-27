import {randomBytes} from 'node:crypto';
import {mkdirSync, readdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {
  DECLINE_FILE_FORMAT_VERSION,
  DECLINE_STORE_RELATIVE_PATH,
  DeclineFileSchema,
} from '../schemas/decline-file.js';
import type {DeclineFile} from '../schemas/decline-file.js';
import {summarizeZodError} from '../schemas/zod-error.js';
import {TALLY_SCHEMA_VERSION} from './material-rise.js';

export type DeclineFileRead = {entry: DeclineFile; relativePath: string};

export type DeclineStoreRead = {
  files: DeclineFileRead[];
  skipped: {reason: string; relativePath: string}[];
};

const DAY_MS = 86_400_000;

const MAX_CLASS_SLUG_LENGTH = 80;

const storeFolder = (repoRoot: string): string =>
  path.join(repoRoot, ...DECLINE_STORE_RELATIVE_PATH.split('/'));

const describeError = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

type ParsedFile = {entry: DeclineFile; ok: true} | {ok: false; reason: string};

const parseDeclineFile = (
  absolutePath: string,
  relativePath: string
): ParsedFile => {
  let parsed: unknown;

  try {
    parsed = JSON.parse(readFileSync(absolutePath, 'utf8'));
  } catch (error) {
    return {
      ok: false,
      reason: `unreadable or invalid JSON: ${describeError(error)}`,
    };
  }

  // A file this reader does not understand is skipped rather than parsed:
  // reading it as a re-surface would silently undo a decline, and reading
  // it as a suppression would hide a class on a guess.
  const formatVersion =
    typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed) ?
      (parsed as Record<string, unknown>).format_version
    : undefined;

  if (formatVersion !== DECLINE_FILE_FORMAT_VERSION) {
    return {
      ok: false,
      reason: `unknown format_version: ${formatVersion === undefined ? 'missing' : JSON.stringify(formatVersion)}`,
    };
  }

  const validated = DeclineFileSchema.safeParse(parsed);

  if (!validated.success) {
    return {
      ok: false,
      reason: summarizeZodError(relativePath, validated.error),
    };
  }

  return {entry: validated.data, ok: true};
};

const byName = (left: string, right: string): number =>
  left.localeCompare(right);

/** Reads every `*.json` decline file; an unusable file is reported, never guessed at. */
export const readDeclineStore = (repoRoot: string): DeclineStoreRead => {
  const folder = storeFolder(repoRoot);
  let names: string[];

  try {
    names = readdirSync(folder)
      .filter((name) => name.endsWith('.json'))
      .toSorted(byName);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return {files: [], skipped: []};
    }

    return {
      files: [],
      skipped: [
        {
          reason: `unreadable decline folder: ${describeError(error)}`,
          relativePath: DECLINE_STORE_RELATIVE_PATH,
        },
      ],
    };
  }

  const result: DeclineStoreRead = {files: [], skipped: []};

  for (const name of names) {
    const relativePath = `${DECLINE_STORE_RELATIVE_PATH}/${name}`;
    const parsed = parseDeclineFile(path.join(folder, name), relativePath);

    if (parsed.ok) {
      result.files.push({entry: parsed.entry, relativePath});
    } else {
      result.skipped.push({reason: parsed.reason, relativePath});
    }
  }

  return result;
};

const trimDashes = (value: string): string => {
  let first = 0;
  let last = value.length;

  while (first < last && value[first] === '-') first += 1;
  while (last > first && value[last - 1] === '-') last -= 1;

  return value.slice(first, last);
};

const classSlug = (findingClass: string): string => {
  const collapsed = findingClass.toLowerCase().replaceAll(/[^a-z0-9]+/gu, '-');
  const slug = trimDashes(
    trimDashes(collapsed).slice(0, MAX_CLASS_SLUG_LENGTH)
  );

  return slug === '' ? 'class' : slug;
};

/** Builds the lowercase ASCII file name for a decline from its class, UTC instant and suffix. */
export const declineFileName = ({
  declinedAt,
  findingClass,
  suffix,
}: {
  declinedAt: Date;
  findingClass: string;
  suffix: string;
}): string => {
  const [datePart = '', timePart = ''] = declinedAt.toISOString().split('T');
  const date = datePart.replaceAll('-', '');
  const time = timePart.replace('Z', '').replaceAll(/[:.]/gu, '');

  return `${classSlug(findingClass)}-${date}-${time}-${suffix}.json`;
};

/** Creates one new decline file (never overwriting) and returns its repo-relative path. */
export const writeDeclineFile = ({
  auditedPrCount,
  findingClass,
  now,
  prCount,
  randomSuffix = () => randomBytes(4).toString('hex'),
  repoRoot,
}: {
  auditedPrCount: number;
  findingClass: string;
  now: Date;
  prCount: number;
  randomSuffix?: () => string;
  repoRoot: string;
}): {relativePath: string} => {
  const folder = storeFolder(repoRoot);
  const name = declineFileName({
    declinedAt: now,
    findingClass,
    suffix: randomSuffix(),
  });
  /* eslint-disable perfectionist/sort-objects -- serialization order load-bearing, version-first */
  const body = {
    format_version: DECLINE_FILE_FORMAT_VERSION,
    finding_class: findingClass,
    declined_at: now.toISOString(),
    declined_at_pr_count: prCount,
    declined_at_audited_pr_count: auditedPrCount,
    tally_schema_version: TALLY_SCHEMA_VERSION,
  };
  /* eslint-enable perfectionist/sort-objects */

  mkdirSync(folder, {recursive: true});
  // `wx` fails on an existing name, so a suffix collision can never replace
  // another engineer's decline.
  writeFileSync(path.join(folder, name), `${JSON.stringify(body, null, 2)}\n`, {
    flag: 'wx',
  });

  return {relativePath: `${DECLINE_STORE_RELATIVE_PATH}/${name}`};
};

// A future timestamp reads as now so a skewed clock can neither outrank a
// real decline nor postpone its own lapse.
const effectiveInstant = (declinedAt: string, now: Date): number =>
  Math.min(Date.parse(declinedAt), now.getTime());

const basename = (relativePath: string): string =>
  relativePath.slice(relativePath.lastIndexOf('/') + 1);

const supersedes = (
  candidate: DeclineFileRead,
  current: DeclineFileRead,
  now: Date
): boolean => {
  const candidateInstant = effectiveInstant(candidate.entry.declined_at, now);
  const currentInstant = effectiveInstant(current.entry.declined_at, now);

  return (
    candidateInstant > currentInstant ||
    (candidateInstant === currentInstant &&
      basename(candidate.relativePath) > basename(current.relativePath))
  );
};

/** The latest decline per class by parsed instant; an equal instant goes to the byte-wise last basename. */
export const governingDeclines = (
  files: readonly DeclineFileRead[],
  now: Date
): Map<string, DeclineFileRead> => {
  const governing = new Map<string, DeclineFileRead>();

  for (const file of files) {
    const current = governing.get(file.entry.finding_class);

    if (current === undefined || supersedes(file, current, now)) {
      governing.set(file.entry.finding_class, file);
    }
  }

  return governing;
};

/** Whether a decline is older than the window; strictly older, so exactly one window old is still live. */
export const isLapsed = (
  declinedAt: string,
  now: Date,
  windowDays: number
): boolean =>
  now.getTime() - effectiveInstant(declinedAt, now) > windowDays * DAY_MS;

/** Repo-relative paths of parsed decline files past the window; an unparseable file is never listed. */
export const lapsedDeclinePaths = ({
  now,
  repoRoot,
  windowDays,
}: {
  now: Date;
  repoRoot: string;
  windowDays: number;
}): string[] =>
  readDeclineStore(repoRoot)
    .files.filter((file) => isLapsed(file.entry.declined_at, now, windowDays))
    .map((file) => file.relativePath)
    .toSorted(byName);
