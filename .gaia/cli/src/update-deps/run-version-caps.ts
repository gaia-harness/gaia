import type {OutdatedEntry} from './run-outdated.js';
import type {PnpmRunner} from './run-types.js';
import {compareSegments, parseSegments, stripRange} from './version.js';

// ---------- published-version fetch ----------

/**
 * Fetch a package's full published version list via `pnpm view <name> versions
 * --json`. Returns [] on any failure. Shared by the ESLint 9.x cap and the
 * config version-hold cap; results are memoized per run by the caller's cache.
 */
export const fetchPackageVersions = (
  name: string,
  cwd: string,
  pnpmRunner: PnpmRunner
): readonly string[] => {
  const result = pnpmRunner(['view', name, 'versions', '--json'], {cwd});

  if (result.status !== 0) return [];

  const trimmed = result.stdout.trim();

  if (trimmed.length === 0) return [];

  let parsed: unknown;

  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return [];
  }

  if (!Array.isArray(parsed)) return [];

  return parsed.filter((value): value is string => typeof value === 'string');
};

export type VersionFetcher = (name: string) => readonly string[];

type CappedDecision =
  {kind: 'drop'} | {kind: 'pass'} | {kind: 'rewrite'; latest: string};

// ---------- ESLint 9.x cap ----------

const ESLINT_CAPPED = new Set(['@eslint/js', 'eslint']);

const findHighest9x = (versions: readonly string[]): string | undefined => {
  let best: undefined | {raw: string; segments: readonly number[]};

  for (const candidate of versions) {
    const segments = parseSegments(candidate);

    if (
      segments[0] === 9 &&
      (best === undefined || compareSegments(segments, best.segments) > 0)
    ) {
      best = {raw: candidate, segments};
    }
  }

  return best?.raw;
};

export const applyEslintCap = (
  entry: OutdatedEntry,
  getVersions: VersionFetcher
): CappedDecision => {
  if (!ESLINT_CAPPED.has(entry.name)) return {kind: 'pass'};

  const latestSegments = parseSegments(entry.latest);

  if ((latestSegments[0] ?? 0) < 10) return {kind: 'pass'};

  const highest9x = findHighest9x(getVersions('eslint'));

  if (highest9x === undefined) {
    // Cap requested but no 9.x line exists upstream; drop the entry to
    // avoid surfacing it. Adopters know about the cap; surfacing is noise.
    return {kind: 'drop'};
  }

  const currentSegments = parseSegments(entry.current);

  if (compareSegments(currentSegments, parseSegments(highest9x)) >= 0) {
    return {kind: 'drop'};
  }

  return {kind: 'rewrite', latest: highest9x};
};

// ---------- config version-hold cap ----------

/**
 * Whether `version`'s leading segments equal the ceiling's. The ceiling pins as
 * many leading segments as it lists: `"8.0"` (two segments) matches any
 * `8.0.x`, `"8.0.16"` matches only `8.0.16`, `"8"` matches any `8.x`.
 */
const matchesCeilingPrefix = (version: string, ceiling: string): boolean => {
  const ceilingParts =
    stripRange(ceiling)
      .split(/[+-]/u, 1)[0]
      ?.split('.')
      .filter((part) => part.length > 0) ?? [];

  if (ceilingParts.length === 0) return false;

  const versionSegments = parseSegments(version);

  for (const [index, ceilingPart] of ceilingParts.entries()) {
    const pinned = Number.parseInt(ceilingPart, 10);

    if (!Number.isFinite(pinned)) return false;
    if ((versionSegments[index] ?? 0) !== pinned) return false;
  }

  return true;
};

/**
 * Highest STABLE published version on the ceiling line, i.e. the newest version
 * whose leading segments match `ceiling`. Prereleases are skipped.
 */
const findHighestUnderCeiling = (
  versions: readonly string[],
  ceiling: string
): string | undefined => {
  let best: undefined | {raw: string; segments: readonly number[]};

  for (const candidate of versions) {
    // Prerelease versions are skipped: only a stable version can serve as
    // the held ceiling's highest published version.
    if (!candidate.includes('-') && matchesCeilingPrefix(candidate, ceiling)) {
      const segments = parseSegments(candidate);

      if (best === undefined || compareSegments(segments, best.segments) > 0) {
        best = {raw: candidate, segments};
      }
    }
  }

  return best?.raw;
};

/**
 * Apply a config version hold. A held package is capped to its ceiling line:
 * `pass` when `latest` already sits on it (offer normally); `rewrite` to an
 * in-ceiling upgrade over `current` (e.g. a patch on the held line); or `drop`
 * when nothing on the ceiling line beats `current` (held at the installed
 * version), or the ceiling matches no published version (fail-closed, never let
 * a held package jump above its ceiling).
 */
export const applyHoldCap = (
  params: {current: string; latest: string; name: string},
  holds: ReadonlyMap<string, string>,
  getVersions: VersionFetcher
): CappedDecision => {
  const ceiling = holds.get(params.name);

  if (ceiling === undefined) return {kind: 'pass'};
  if (matchesCeilingPrefix(params.latest, ceiling)) return {kind: 'pass'};

  const capped = findHighestUnderCeiling(getVersions(params.name), ceiling);

  if (capped === undefined) return {kind: 'drop'};

  if (
    compareSegments(parseSegments(capped), parseSegments(params.current)) <= 0
  ) {
    return {kind: 'drop'};
  }

  return {kind: 'rewrite', latest: capped};
};

// ---------- sibling version fetch ----------

/**
 * Fetch the latest published version of a package via `pnpm view <name> version`.
 * Returns `undefined` on any failure (network error, package not found, etc.).
 */
export const fetchLatestVersion = (
  name: string,
  cwd: string,
  pnpmRunner: PnpmRunner
): string | undefined => {
  const result = pnpmRunner(['view', name, 'version'], {cwd});

  if (result.status !== 0) return undefined;

  const trimmed = result.stdout.trim();

  return trimmed.length > 0 ? trimmed : undefined;
};
