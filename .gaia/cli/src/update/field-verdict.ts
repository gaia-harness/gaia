/**
 * The three-way verdict shared by `merge-package`, `merge-workspace` and
 * `merge-audit-ci`. Each command builds one triple per key from its own file
 * format and hands the triples here, so the table lives in one place.
 */
import semver from 'semver';

export type FieldMergeReport = {
  alreadyLatest: VerdictItem[];
  applied: VerdictItem[];
  conflicts: VerdictItem[];
  keptRemoved: VerdictItem[];
  removedUpstream: VerdictItem[];
};

export type Presence = {has: boolean; value: unknown};

export type Recommendation = {
  option: 'gaia' | 'higher' | 'keep';
  reason: string;
  side?: 'adopter' | 'gaia';
  value: unknown;
};

export type Triple = {
  a: Presence;
  b: Presence;
  key: string;
  kind: 'entry' | 'key';
  l: Presence;
  section?: string;
  versionValued?: boolean;
};

export type Verdict =
  | 'added'
  | 'alreadyLatest'
  | 'changed'
  | 'conflict'
  | 'keptRemoved'
  | 'noop'
  | 'removedUpstream';

export type VerdictItem = {
  adopter?: unknown;
  baseline?: unknown;
  key: string;
  kind: 'entry' | 'key';
  latest?: unknown;
  reason?: 'added' | 'changed';
  recommendation?: Recommendation;
  section?: string;
  versionValued?: boolean;
};

export const absent: Presence = {has: false, value: undefined};

export const lookup = (root: Record<string, unknown>, key: string): Presence =>
  Object.hasOwn(root, key) ?
    {has: true, value: root[key]}
  : {has: false, value: undefined};

export const asRecord = (value: unknown): Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value) ?
    (value as Record<string, unknown>)
  : {};

export const deepEqual = (a: unknown, b: unknown): boolean => {
  if (a === b) return true;
  if (a === null || b === null) return a === b;
  if (typeof a !== typeof b) return false;

  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b)) return false;
    if (a.length !== b.length) return false;

    return a.every((value, index) => deepEqual(value, b[index]));
  }

  if (typeof a === 'object' && typeof b === 'object') {
    const aKeys = Object.keys(a);
    const bKeys = Object.keys(b);

    if (aKeys.length !== bKeys.length) return false;

    return aKeys.every((key) =>
      deepEqual(
        (a as Record<string, unknown>)[key],
        (b as Record<string, unknown>)[key]
      )
    );
  }

  return false;
};

type VerdictInputs = Pick<Triple, 'a' | 'b' | 'l'>;

const changedUpstreamVerdict = ({a, b, l}: VerdictInputs): Verdict => {
  if (deepEqual(b.value, l.value)) return 'noop';
  if (!a.has) return 'keptRemoved';
  if (deepEqual(a.value, l.value)) return 'alreadyLatest';
  if (deepEqual(a.value, b.value)) return 'changed';

  return 'conflict';
};

const addedUpstreamVerdict = ({a, l}: VerdictInputs): Verdict => {
  if (!a.has) return 'added';

  return deepEqual(a.value, l.value) ? 'alreadyLatest' : 'conflict';
};

/** One key's verdict from its baseline, latest and adopter presence. */
export const computeVerdict = (inputs: VerdictInputs): Verdict => {
  if (inputs.b.has && inputs.l.has) return changedUpstreamVerdict(inputs);
  if (inputs.l.has) return addedUpstreamVerdict(inputs);

  return inputs.b.has && inputs.a.has ? 'removedUpstream' : 'noop';
};

/** The stable id of a triple: `section.key`, or the bare key. */
export const tripleId = (triple: Pick<Triple, 'key' | 'section'>): string =>
  triple.section === undefined ? triple.key : `${triple.section}.${triple.key}`;

// A non-semver spec (workspace:, catalog:, npm:, a git or file URL, link:) is
// not a valid range, so validRange rejecting it is what routes it to `keep`.
// packageManager carries `name@version+hash`; only the version orders.
const lowerBound = (spec: unknown, isPackageManager: boolean) => {
  if (typeof spec !== 'string') return null;

  const text =
    isPackageManager ? (spec.split('@').at(-1) ?? '').split('+', 1)[0] : spec;

  if (text === undefined || semver.validRange(text) === null) return null;

  return semver.minVersion(text);
};

const keepRecommendation = (item: VerdictItem, reason: string) => ({
  option: 'keep' as const,
  reason,
  value: item.adopter,
});

const recommendVersion = (item: VerdictItem): Recommendation => {
  const isPackageManager =
    item.section === undefined && item.key === 'packageManager';
  const adopterBound = lowerBound(item.adopter, isPackageManager);
  const gaiaBound = lowerBound(item.latest, isPackageManager);

  if (adopterBound === null || gaiaBound === null) {
    return keepRecommendation(
      item,
      'a version spec that is not a semver range has no order to compare'
    );
  }

  if (semver.gt(gaiaBound, adopterBound)) {
    return {
      option: 'higher',
      reason: `GAIA's ${gaiaBound.version} is higher than your ${adopterBound.version}`,
      side: 'gaia',
      value: item.latest,
    };
  }

  if (semver.gt(adopterBound, gaiaBound)) {
    return {
      option: 'higher',
      reason: `your ${adopterBound.version} is higher than GAIA's ${gaiaBound.version}`,
      side: 'adopter',
      value: item.adopter,
    };
  }

  return keepRecommendation(
    item,
    'both sides pin the same lower bound, so neither is higher'
  );
};

/** The recommended answer to a conflict item. */
export const recommend = (item: VerdictItem): Recommendation =>
  item.versionValued === true ?
    recommendVersion(item)
  : keepRecommendation(
      item,
      'not a version, so there is no order; keeping your value is the safe default'
    );

const buildItem = (triple: Triple): VerdictItem => {
  const item: VerdictItem = {key: triple.key, kind: triple.kind};

  if (triple.section !== undefined) item.section = triple.section;
  if (triple.b.has) item.baseline = triple.b.value;
  if (triple.l.has) item.latest = triple.l.value;
  if (triple.a.has) item.adopter = triple.a.value;

  return item;
};

// U+0000 separates section from key because collation ignores it entirely, so
// items order by section-then-key with nothing of the separator's own weight
// competing in the comparison. It stays written as an escape: a raw NUL byte
// here lands inside git's binary-sniff window and makes the whole file read as
// binary, which drops it out of `git grep` and every plain-text diff.
const sortKey = (item: VerdictItem): string =>
  `${item.section ?? ''}\u0000${item.key}`;

const bySortKey = (a: VerdictItem, b: VerdictItem): number =>
  sortKey(a).localeCompare(sortKey(b));

/** Classifies every triple into the five report buckets, each sorted. */
export const classifyTriples = (
  triples: readonly Triple[]
): FieldMergeReport => {
  const report: FieldMergeReport = {
    alreadyLatest: [],
    applied: [],
    conflicts: [],
    keptRemoved: [],
    removedUpstream: [],
  };

  for (const triple of triples) {
    const verdict = computeVerdict(triple);
    const item = buildItem(triple);

    if (verdict === 'added' || verdict === 'changed') {
      item.reason = verdict;
      report.applied.push(item);
    } else if (verdict === 'conflict') {
      item.versionValued = triple.versionValued === true;
      item.recommendation = recommend(item);
      report.conflicts.push(item);
    } else if (verdict === 'alreadyLatest') {
      report.alreadyLatest.push(item);
    } else if (verdict === 'keptRemoved') {
      report.keptRemoved.push(item);
    } else if (verdict === 'removedUpstream') {
      report.removedUpstream.push(item);
    }
  }

  return {
    alreadyLatest: report.alreadyLatest.toSorted(bySortKey),
    applied: report.applied.toSorted(bySortKey),
    conflicts: report.conflicts.toSorted(bySortKey),
    keptRemoved: report.keptRemoved.toSorted(bySortKey),
    removedUpstream: report.removedUpstream.toSorted(bySortKey),
  };
};

const DEFERRED_FLAG = '--deferred-baseline';

export type DeferredBaselineArgs =
  | {
      /** `<key>` to file path, in argv order. */
      deferred: Map<string, string>;
      ok: true;
      /** argv with every `--deferred-baseline <key>=<file>` pair removed. */
      rest: string[];
    }
  | {message: string; ok: false};

/** Splits the repeatable `--deferred-baseline <key>=<file>` pairs out of argv. */
export const extractDeferredBaselines = (
  argv: readonly string[]
): DeferredBaselineArgs => {
  const deferred = new Map<string, string>();
  const rest: string[] = [];
  let index = 0;

  while (index < argv.length) {
    const token = argv[index];

    if (token === DEFERRED_FLAG) {
      const pair = argv[index + 1] ?? '';
      const separator = pair.indexOf('=');

      if (separator < 1 || separator === pair.length - 1) {
        return {message: `${DEFERRED_FLAG} requires <key>=<file>`, ok: false};
      }

      deferred.set(pair.slice(0, separator), pair.slice(separator + 1));
      index += 2;
    } else {
      if (token !== undefined) rest.push(token);
      index += 1;
    }
  }

  return {deferred, ok: true, rest};
};

type BaselineTriples<TRoot> = (baseline: TRoot) => Triple[];

/**
 * Builds the triples against the shared baseline, then replaces each deferred
 * key's triple with the one built against the bundle it was deferred from.
 * A key present only in a deferred baseline is visited too.
 */
export const triplesWithDeferred = <TRoot>(
  build: BaselineTriples<TRoot>,
  baseline: TRoot,
  deferredRoots: ReadonlyMap<string, TRoot>
): Triple[] => {
  const triples = build(baseline).filter(
    (triple) => !deferredRoots.has(tripleId(triple))
  );

  for (const [id, deferredRoot] of deferredRoots) {
    const match = build(deferredRoot).find((triple) => tripleId(triple) === id);

    if (match !== undefined) triples.push(match);
  }

  return triples;
};

export const itemLabel = (item: VerdictItem): string => tripleId(item);

const BUCKET_HEADINGS: readonly [keyof FieldMergeReport, string][] = [
  ['applied', 'Applied'],
  ['conflicts', 'Conflicts'],
  ['alreadyLatest', 'Already latest'],
  ['keptRemoved', 'Kept removed'],
  ['removedUpstream', 'Removed upstream'],
];

/** The human summary every merge command prints without `--json`. */
export const renderHumanReport = (
  command: string,
  report: FieldMergeReport
): string => {
  const lines = [command];

  for (const [bucket, heading] of BUCKET_HEADINGS) {
    const label = `${heading}:`.padEnd(17);

    lines.push(`  ${label}${report[bucket].length}`);
  }

  for (const [bucket, heading] of BUCKET_HEADINGS) {
    if (report[bucket].length > 0) {
      lines.push('', `${heading}:`);

      for (const item of report[bucket]) lines.push(`  ${itemLabel(item)}`);
    }
  }

  return `${lines.join('\n')}\n`;
};
