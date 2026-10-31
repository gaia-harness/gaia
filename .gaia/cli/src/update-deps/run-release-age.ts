import {readFileSync} from 'node:fs';
import path from 'node:path';
import {escapeRegExp} from '../util/escape-regexp.js';
import type {PnpmRunner} from './run-types.js';
import {compareSegments, parseSegments} from './version.js';
import {readWorkspaceYaml} from './workspace-member.js';

// ---------- release-age cooldown ----------

/**
 * Read `minimumReleaseAge` (in minutes) from the workspace's
 * `pnpm-workspace.yaml`. Returns 0 when the file is absent, unparsable, or the
 * key is missing / non-positive; in which case the cooldown is a no-op and
 * the version selection matches the pre-cooldown behaviour exactly (no extra
 * registry calls). pnpm 11 enforces this same setting on the lockfile; honour
 * it here so the /update-deps flow never targets a version pnpm 11 would reject.
 */
export const readMinimumReleaseAge = (cwd: string): number => {
  let raw: string;

  try {
    raw = readFileSync(path.join(cwd, 'pnpm-workspace.yaml'), 'utf8');
  } catch {
    return 0;
  }

  // The setting is a top-level integer minute count. Match it directly rather
  // than pulling a YAML parser into the bundle for one scalar; commented and
  // indented lines do not match the start-anchored key, and any inline comment
  // sits past the captured digits.
  for (const line of raw.split('\n')) {
    const match = /^minimumReleaseAge:[ \t]*(\d+)\b/u.exec(line);

    if (match) {
      const [, rawValue] = match;

      if (rawValue === undefined)
        throw new Error(
          'minimumReleaseAge matched without its digit group; refusing to treat a configured cooldown as zero'
        );

      const value = Number.parseInt(rawValue, 10);

      return Number.isFinite(value) && value > 0 ? value : 0;
    }
  }

  return 0;
};

/**
 * Read the `minimumReleaseAgeExclude` entries from the workspace's
 * `pnpm-workspace.yaml`. Returns an empty list when the file is absent or
 * unparsable, so a read failure leaves the cooldown in force rather than
 * lifting it.
 */
export const readMinimumReleaseAgeExclude = (
  repoRoot: string
): readonly string[] => {
  const workspace = readWorkspaceYaml(repoRoot);

  if (typeof workspace !== 'object' || workspace === null) return [];

  const {minimumReleaseAgeExclude: entries} = workspace as {
    minimumReleaseAgeExclude?: unknown;
  };

  return Array.isArray(entries) ?
      entries.filter((entry): entry is string => typeof entry === 'string')
    : [];
};

/** The versions of one package that `minimumReleaseAgeExclude` exempts. */
export type ReleaseAgeExemption = {
  coversEveryVersion: boolean;
  exactVersions: ReadonlySet<string>;
};

const parseExcludeEntry = (
  entry: string
): {name: string; versions: readonly string[]} => {
  // Searching from index 1 skips a scope's leading `@`.
  const separatorIndex = entry.indexOf('@', 1);

  if (separatorIndex === -1) return {name: entry, versions: []};

  return {
    name: entry.slice(0, separatorIndex),
    versions: entry
      .slice(separatorIndex + 1)
      .split('||')
      .map((version) => version.trim()),
  };
};

const matchesNamePattern = (pattern: string, packageName: string): boolean =>
  new RegExp(`^${pattern.split('*').map(escapeRegExp).join('.*')}$`, 'u').test(
    packageName
  );

/**
 * Which versions of `packageName` the exclude entries exempt, by pnpm's
 * documented forms: a bare name or `*` pattern covers every version, and
 * `name@version` or `name@v1 || v2` covers those exact versions. pnpm rejects
 * a range or a `*` pattern beside a version, and neither compares equal here,
 * so the cooldown stays in force. Its matcher also takes `?` and a leading `!`,
 * which it does not document; those exempt nothing here, which at worst holds
 * a package back until it ages.
 */
export const resolveReleaseAgeExemption = (
  excludes: readonly string[],
  packageName: string
): ReleaseAgeExemption => {
  const exactVersions = new Set<string>();

  for (const entry of excludes) {
    const {name, versions} = parseExcludeEntry(entry);

    if (versions.length === 0) {
      if (matchesNamePattern(name, packageName)) {
        return {coversEveryVersion: true, exactVersions};
      }
    } else if (name === packageName) {
      for (const version of versions) exactVersions.add(version);
    }
  }

  return {coversEveryVersion: false, exactVersions};
};

/**
 * Fetch a package's `version -> ISO publish time` table via
 * `pnpm view <name> time --json`. Returns `undefined` on any failure so the
 * caller can fail closed (record the package as unresolved rather than bump to
 * a possibly-too-young version).
 */
export const fetchVersionTimes = (
  name: string,
  cwd: string,
  pnpmRunner: PnpmRunner
): Readonly<Record<string, string>> | undefined => {
  const result = pnpmRunner(['view', name, 'time', '--json'], {cwd});

  if (result.status !== 0) return undefined;

  const trimmed = result.stdout.trim();

  if (trimmed.length === 0) return undefined;

  let parsed: unknown;

  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return undefined;
  }

  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return undefined;
  }

  const out: Record<string, string> = {};

  for (const [version, time] of Object.entries(
    parsed as Record<string, unknown>
  )) {
    if (typeof time === 'string') out[version] = time;
  }

  return out;
};

/** A semver string is a prerelease when it carries a `-` qualifier. */
const isPrerelease = (version: string): boolean => version.includes('-');

type AgedVersionBounds = {
  currentSegments: readonly number[];
  cutoffMs: number;
  exemptVersions: ReadonlySet<string>;
  latestSegments: readonly number[];
};

/**
 * Whether `version` (published at `isoTime`) is a candidate aged-upgrade
 * target: not a `time --json` pseudo-key, not a prerelease, strictly above
 * `current`, at or below `latest`, and published on or before the cooldown
 * cutoff unless exempt from it. Returns the parsed segments for the ranking
 * comparison, or `null` when disqualified.
 */
const evaluateAgedCandidate = (
  version: string,
  isoTime: string,
  bounds: AgedVersionBounds
): null | {raw: string; segments: readonly number[]} => {
  if (version === 'created' || version === 'modified') return null;
  if (isPrerelease(version)) return null;

  const segments = parseSegments(version);

  if (compareSegments(segments, bounds.currentSegments) <= 0) return null;
  if (compareSegments(segments, bounds.latestSegments) > 0) return null;

  if (bounds.exemptVersions.has(version)) return {raw: version, segments};

  const publishedMs = Date.parse(isoTime);

  if (!Number.isFinite(publishedMs) || publishedMs > bounds.cutoffMs) {
    return null;
  }

  return {raw: version, segments};
};

/**
 * The newest stable version that is an upgrade over `current`, at or below
 * `latest`, and either published on or before `cutoffMs` or listed in
 * `exemptVersions`. Returns `undefined` when no such version exists; every
 * available upgrade is still inside the cooldown window. `time` carries
 * `created` / `modified` pseudo-keys alongside the real version keys; both are
 * skipped.
 */
export const capToAgedVersion = (params: {
  current: string;
  cutoffMs: number;
  exemptVersions: ReadonlySet<string>;
  latest: string;
  times: Readonly<Record<string, string>>;
}): string | undefined => {
  const bounds: AgedVersionBounds = {
    currentSegments: parseSegments(params.current),
    cutoffMs: params.cutoffMs,
    exemptVersions: params.exemptVersions,
    latestSegments: parseSegments(params.latest),
  };
  let best: undefined | {raw: string; segments: readonly number[]};

  for (const [version, isoTime] of Object.entries(params.times)) {
    const candidate = evaluateAgedCandidate(version, isoTime, bounds);

    if (
      candidate !== null &&
      (best === undefined ||
        compareSegments(candidate.segments, best.segments) > 0)
    ) {
      best = candidate;
    }
  }

  return best?.raw;
};
