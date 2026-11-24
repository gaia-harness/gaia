import type {ParsedMarker} from './markers.js';
import {parseMarker} from './markers.js';
import type {FileReading, MarkerComment, ValueSet} from './types.js';

/** A collected set with its comparison values: deduped, sorted by code point. */
export type Entry = {
  key: string;
  set: ValueSet;
  values: readonly string[];
};

/** One strict finding before suppression and ordering. */
export type Finding = {
  firstLine: number;
  firstPath: string;
  sitePaths: readonly string[];
  text: string;
};

export type MarkerVerdicts = {
  findings: readonly Finding[];
  validCopies: ReadonlySet<Entry>;
  validSubsets: ReadonlySet<Entry>;
};

const FINDING_PREFIX = 'value-sets: ';

/** Orders strings by Unicode code point, not UTF-16 code unit. */
export const compareCodePoints = (left: string, right: string): number => {
  const leftPoints = Array.from(left, (point) => point.codePointAt(0) ?? 0);
  const rightPoints = Array.from(right, (point) => point.codePointAt(0) ?? 0);
  const shared = Math.min(leftPoints.length, rightPoints.length);

  for (let index = 0; index < shared; index += 1) {
    const difference = (leftPoints[index] ?? 0) - (rightPoints[index] ?? 0);
    if (difference !== 0) return difference;
  }

  return leftPoints.length - rightPoints.length;
};

/** Orders sets by path, then line. */
export const compareSites = (
  left: {line: number; path: string},
  right: {line: number; path: string}
): number => compareCodePoints(left.path, right.path) || left.line - right.line;

const sortValues = (values: Iterable<string>): string[] => {
  const distinct = [...new Set(values)];

  return distinct.toSorted(compareCodePoints);
};

export const joinValues = (values: readonly string[]): string =>
  values.length === 0 ? 'none' : values.join(', ');

/** `<name> (<path>:<line>)`, with `(case arm)` or `(unnamed)` for a set with no name. */
export const siteText = (set: ValueSet): string => {
  const label =
    set.origin === 'case-arm' ? '(case arm)' : (set.name ?? '(unnamed)');

  return `${label} (${set.path}:${set.line})`;
};

/** Every set of two or more distinct values; smaller sets take part in nothing. */
export const collectEntries = (
  readings: readonly FileReading[]
): readonly Entry[] =>
  readings
    .flatMap((reading) => reading.sets)
    .map((set) => {
      const values = sortValues(set.values);

      return {key: values.join('\0'), set, values};
    })
    .filter((entry) => entry.values.length >= 2);

export const makeFinding = (
  first: {line: number; path: string},
  sitePaths: readonly string[],
  body: string
): Finding => ({
  firstLine: first.line,
  firstPath: first.path,
  sitePaths,
  text: `${FINDING_PREFIX}${body}`,
});

type ResolvedMarker = Exclude<ParsedMarker, {kind: 'malformed'}>;

const markerKinds = (entry: Entry): readonly ParsedMarker['kind'][] =>
  entry.set.markers.map((marker) => parseMarker(marker.text).kind);

/** The finding body for a marker with exactly one source, or undefined when the marker holds. */
const judgeAgainstSource = (
  entry: Entry,
  marker: ResolvedMarker,
  source: Entry
): string | undefined => {
  const site = siteText(entry.set);
  const reference = `${marker.path}#${marker.name}`;
  const sourceKinds = markerKinds(source);

  if (marker.kind === 'sanctioned-copy') {
    if (sourceKinds.includes('sanctioned-copy')) {
      return `copy of a copy: ${site} names ${reference}, which is itself a sanctioned copy`;
    }

    if (sourceKinds.length > 0) {
      return `marked source: ${site} names ${reference}, which itself carries a marker`;
    }
    if (entry.key === source.key) return undefined;
    const held = new Set(entry.values);
    const sourceValues = new Set(source.values);
    const missing = source.values.filter((value) => !held.has(value));
    const extra = entry.values.filter((value) => !sourceValues.has(value));

    return `copy drifted: ${site} copies ${reference}; missing ${joinValues(missing)}; extra ${joinValues(extra)}`;
  }

  if (sourceKinds.length > 0) {
    return `marked source: ${site} names ${reference}, which itself carries a marker`;
  }
  const sourceValues = new Set(source.values);
  const lacking = entry.values.filter((value) => !sourceValues.has(value));

  if (lacking.length > 0) {
    return `subset holds values its source lacks: ${site} holds ${joinValues(lacking)}, which ${reference} lacks`;
  }

  if (entry.values.length === source.values.length) {
    return `subset equals source: ${site} holds no value fewer than ${reference}; it is a duplicate, not a subset`;
  }

  return undefined;
};

/** The finding body for one marked set, or undefined when its marker holds. */
const judgeMarker = (
  entry: Entry,
  comment: MarkerComment,
  namedSets: ReadonlyMap<string, readonly Entry[]>
): string | undefined => {
  const site = siteText(entry.set);

  if (entry.set.markers.length > 1) {
    return `conflicting markers: ${site} carries both`;
  }
  const marker = parseMarker(comment.text);

  if (marker.kind === 'malformed') {
    return `malformed marker: ${entry.set.path}:${comment.line}`;
  }
  const reference = `${marker.path}#${marker.name}`;
  const matches = namedSets.get(reference) ?? [];
  const [source, ...otherMatches] = matches;

  if (source === undefined) {
    const kind = marker.kind === 'subset' ? 'subset' : 'copy';

    return `${kind} source not found: ${site} names ${reference}`;
  }

  if (otherMatches.length > 0) {
    const lines = matches
      .map((match) => match.set.line)
      .toSorted((left, right) => left - right);

    return `ambiguous source: ${site} names ${reference}, which matches lines ${lines.join(', ')}`;
  }

  return judgeAgainstSource(entry, marker, source);
};

/**
 * Verifies every marker and stray marker. A marker resolves only against a
 * named set already collected, by normalized path and exact name; it never
 * opens the file it names. A marker finding's only site is the marked set.
 */
export const verifyMarkers = (
  readings: readonly FileReading[],
  entries: readonly Entry[]
): MarkerVerdicts => {
  const namedSets = new Map<string, Entry[]>();

  for (const entry of entries) {
    if (entry.set.name !== null) {
      const reference = `${entry.set.path}#${entry.set.name}`;
      namedSets.set(reference, [...(namedSets.get(reference) ?? []), entry]);
    }
  }

  const findings: Finding[] = [];
  const validCopies = new Set<Entry>();
  const validSubsets = new Set<Entry>();

  const marked = entries.flatMap((entry) => {
    const [comment] = entry.set.markers;

    return comment === undefined ? [] : [{comment, entry}];
  });

  for (const {comment, entry} of marked) {
    const body = judgeMarker(entry, comment, namedSets);

    if (body !== undefined) {
      findings.push(makeFinding(entry.set, [entry.set.path], body));
    } else if (parseMarker(comment.text).kind === 'subset') {
      validSubsets.add(entry);
    } else {
      validCopies.add(entry);
    }
  }

  for (const stray of readings.flatMap((reading) => reading.strayMarkers)) {
    findings.push(
      makeFinding(
        stray,
        [stray.path],
        `stray marker: ${stray.path}:${stray.line} sits above no value set`
      )
    );
  }

  return {findings, validCopies, validSubsets};
};
