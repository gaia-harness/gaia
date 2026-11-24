import type {FileReading} from './types.js';
import type {Entry, Finding} from './verify-markers.js';
import {
  collectEntries,
  compareCodePoints,
  compareSites,
  joinValues,
  makeFinding,
  siteText,
  verifyMarkers,
} from './verify-markers.js';

export type Candidate = {
  kind: CandidateKind;
  sites: CandidateSite[];
  values: string[];
};

type CandidateKind =
  'same-file-subset' | 'two-value-duplicate' | 'two-value-subset';

type CandidateSite = {line: number; name: null | string; path: string};

const STRICT_MINIMUM = 3;

const NUMBER = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/u;

/**
 * Small number lists (line numbers, counts, ports) coincide by chance, and no
 * marker can say two sets are unrelated, so a set of only numbers is never compared.
 */
const isNumericOnly = (entry: Entry): boolean =>
  entry.values.every((value) => NUMBER.test(value));

const compareEntries = (left: Entry, right: Entry): number =>
  compareSites(left.set, right.set);

const isStrictSuperset = (superset: Entry, subset: Entry): boolean => {
  if (superset.values.length <= subset.values.length) return false;
  const held = new Set(superset.values);

  return subset.values.every((value) => held.has(value));
};

/** The smallest superset among the candidates, ties broken by path then line. */
const smallestSuperset = (
  subset: Entry,
  candidates: readonly Entry[]
): Entry | undefined =>
  candidates
    .filter((candidate) => isStrictSuperset(candidate, subset))
    .toSorted(
      (left, right) =>
        left.values.length - right.values.length || compareEntries(left, right)
    )
    .at(0);

type Group = readonly [Entry, Entry, ...Entry[]];

/** Identical-value groups of two or more sets, each sorted by site. */
const groupIdentical = (entries: readonly Entry[]): readonly Group[] => {
  const groups = new Map<string, Entry[]>();

  for (const entry of entries) {
    groups.set(entry.key, [...(groups.get(entry.key) ?? []), entry]);
  }

  return [...groups.values()]
    .map((group) => group.toSorted(compareEntries))
    .filter((group): group is [Entry, Entry, ...Entry[]] => group.length > 1);
};

/** Marker verdicts plus the sets that take part in duplicate and subset comparison. */
const prepare = (
  readings: readonly FileReading[]
): {
  compared: readonly Entry[];
  markerFindings: readonly Finding[];
  subsetExempt: ReadonlySet<Entry>;
} => {
  const entries = collectEntries(readings);
  const verdicts = verifyMarkers(readings, entries);

  return {
    compared: entries.filter(
      (entry) => !verdicts.validCopies.has(entry) && !isNumericOnly(entry)
    ),
    markerFindings: verdicts.findings,
    subsetExempt: verdicts.validSubsets,
  };
};

const duplicateFinding = (group: Group): Finding => {
  const values = joinValues(group[0].values);
  const sitePaths = group.map((entry) => entry.set.path);
  const [first, second] = group;
  const arm = first.set.origin === 'case-arm' ? first : second;
  const declaration = arm === first ? second : first;

  if (
    group.length === 2 &&
    arm.set.origin === 'case-arm' &&
    declaration.set.origin === 'declaration'
  ) {
    return makeFinding(
      group[0].set,
      sitePaths,
      `arm copies set: ${siteText(arm.set)} repeats ${siteText(declaration.set)}: ${values}`
    );
  }
  const sites = group.map((entry) => siteText(entry.set)).join(' and ');

  return makeFinding(
    group[0].set,
    sitePaths,
    `duplicate: ${sites} hold ${values}`
  );
};

const subsetFinding = (subset: Entry, superset: Entry): Finding => {
  const held = new Set(subset.values);
  const extra = superset.values.filter((value) => !held.has(value));

  return makeFinding(
    subset.set,
    [subset.set.path, superset.set.path],
    `subset: ${siteText(subset.set)} is a subset of ${siteText(superset.set)}, which also holds ${joinValues(extra)}`
  );
};

/**
 * Cross-file subset findings. A case arm can be the subset, never the
 * superset. Identical sets report once, for the first site in the group that
 * has a superset, so a group never repeats one relation per member.
 */
const findSubsets = (
  compared: readonly Entry[],
  subsetExempt: ReadonlySet<Entry>
): Finding[] => {
  const strict = compared.filter(
    (entry) => entry.values.length >= STRICT_MINIMUM
  );
  const declarations = strict.filter(
    (entry) => entry.set.origin === 'declaration'
  );
  const reportedKeys = new Set<string>();
  const findings: Finding[] = [];

  const candidates = strict
    .filter((entry) => !subsetExempt.has(entry))
    .toSorted(compareEntries);

  for (const subset of candidates) {
    const superset =
      reportedKeys.has(subset.key) ? undefined : (
        smallestSuperset(
          subset,
          declarations.filter((entry) => entry.set.path !== subset.set.path)
        )
      );

    if (superset !== undefined) {
      reportedKeys.add(subset.key);
      findings.push(subsetFinding(subset, superset));
    }
  }

  return findings;
};

const isReported = (
  sitePaths: readonly string[],
  harnessPaths: ReadonlySet<string>
): boolean => sitePaths.some((sitePath) => !harnessPaths.has(sitePath));

/** Every strict finding as its stdout line in its fixed line form, ordered; empty when clean. */
export const findStrict = (
  readings: readonly FileReading[],
  harnessPaths: ReadonlySet<string>
): readonly string[] => {
  const {compared, markerFindings, subsetExempt} = prepare(readings);
  const duplicates = groupIdentical(
    compared.filter((entry) => entry.values.length >= STRICT_MINIMUM)
  ).map((group) => duplicateFinding(group));

  return [
    ...markerFindings,
    ...duplicates,
    ...findSubsets(compared, subsetExempt),
  ]
    .filter((finding) => isReported(finding.sitePaths, harnessPaths))
    .toSorted(
      (left, right) =>
        compareSites(
          {line: left.firstLine, path: left.firstPath},
          {line: right.firstLine, path: right.firstPath}
        ) || compareCodePoints(left.text, right.text)
    )
    .map((finding) => finding.text);
};

const toSite = (entry: Entry): CandidateSite => ({
  line: entry.set.line,
  name: entry.set.name,
  path: entry.set.path,
});

const candidate = (
  kind: CandidateKind,
  sites: readonly Entry[],
  values: readonly string[]
): Candidate => ({kind, sites: sites.map(toSite), values: [...values]});

const compareCandidates = (left: Candidate, right: Candidate): number => {
  const shared = Math.min(left.sites.length, right.sites.length);

  for (let index = 0; index < shared; index += 1) {
    const leftSite = left.sites[index];
    const rightSite = right.sites[index];
    const order = leftSite && rightSite ? compareSites(leftSite, rightSite) : 0;
    if (order !== 0) return order;
  }

  return (
    left.sites.length - right.sites.length ||
    compareCodePoints(left.kind, right.kind)
  );
};

/** Every weaker match (the `--candidates` list), ordered by first site path then line. */
export const findCandidates = (
  readings: readonly FileReading[],
  harnessPaths: ReadonlySet<string>
): readonly Candidate[] => {
  const {compared, subsetExempt} = prepare(readings);
  const pairs = compared.filter((entry) => entry.values.length === 2);
  const strict = compared.filter(
    (entry) => entry.values.length >= STRICT_MINIMUM
  );

  const twoValueDuplicates = groupIdentical(pairs).map((group) =>
    candidate('two-value-duplicate', group, group[0].values)
  );

  const twoValueSubsets = pairs.flatMap((subset) => {
    if (subsetExempt.has(subset)) return [];
    const superset = smallestSuperset(subset, compared);

    return superset === undefined ?
        []
      : [candidate('two-value-subset', [subset, superset], subset.values)];
  });

  const sameFileSubsets = strict.flatMap((subset) =>
    subsetExempt.has(subset) ?
      []
    : strict
        .filter(
          (superset) =>
            superset.set.path === subset.set.path &&
            isStrictSuperset(superset, subset)
        )
        .toSorted(compareEntries)
        .map((superset) =>
          candidate('same-file-subset', [subset, superset], subset.values)
        )
  );

  return [...twoValueDuplicates, ...twoValueSubsets, ...sameFileSubsets]
    .filter((found) =>
      isReported(
        found.sites.map((site) => site.path),
        harnessPaths
      )
    )
    .toSorted(compareCandidates);
};
