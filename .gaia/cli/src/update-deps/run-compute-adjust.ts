import {resolveGroup} from './groups.js';
import {classifyKind, isPinnedSpec, lookupSpec} from './run-outdated.js';
import type {OutdatedEntry, PackageJsonShape} from './run-outdated.js';
import {capToAgedVersion, fetchVersionTimes} from './run-release-age.js';
import type {Kind, PnpmRunner, SkippedEntry} from './run-types.js';
import {
  applyEslintCap,
  applyHoldCap,
  fetchPackageVersions,
} from './run-version-caps.js';
import type {VersionFetcher} from './run-version-caps.js';
import {compareSegments, parseSegments} from './version.js';

// ---------- compute ----------

export type Adjusted = {
  current: string;
  group: string;
  is_pinned: boolean;
  kind: Kind;
  latest: string;
  name: string;
  wanted: string;
};

export type ComputeOptions = {
  cwd: string;
  now?: () => Date;
  pnpmRunner?: PnpmRunner;
};

export type CooldownContext = {
  cooldownCutoffMs: number;
  cwd: string;
  minimumReleaseAgeMinutes: number;
  pnpmRunner: PnpmRunner;
};

type CooldownDecision =
  {kind: 'cooldown'} | {kind: 'ok'; latest: string} | {kind: 'unresolved'};

/**
 * Release-age cooldown for one target: pnpm 11 re-verifies the whole
 * lockfile against `minimumReleaseAge`, so a target newer than the cooldown
 * window would make the resulting install fail. Caps `latest` to the newest
 * version that has already cleared the window. A no-op (`kind: 'ok'`) when
 * the cooldown is disabled or `latest` is not actually an upgrade.
 */
export const applyCooldown = (args: {
  context: CooldownContext;
  current: string;
  latest: string;
  name: string;
}): CooldownDecision => {
  const {context, current, latest, name} = args;

  if (context.minimumReleaseAgeMinutes <= 0) return {kind: 'ok', latest};

  // Not an upgrade (sibling already current, or a downgrade); nothing to
  // gate; leave it so up-to-date members still flow through unchanged.
  if (compareSegments(parseSegments(latest), parseSegments(current)) <= 0) {
    return {kind: 'ok', latest};
  }

  const times = fetchVersionTimes(name, context.cwd, context.pnpmRunner);

  if (times === undefined) return {kind: 'unresolved'};

  const capped = capToAgedVersion({
    current,
    cutoffMs: context.cooldownCutoffMs,
    latest,
    times,
  });

  return capped === undefined ?
      {kind: 'cooldown'}
    : {kind: 'ok', latest: capped};
};

/**
 * `wanted` is the in-range floor pnpm reports; never let it exceed the
 * cooldown-capped target, or the emitted payload would be self-inconsistent.
 * Pure (no closure capture), so it lives at module scope rather than nested
 * inside `computeUpdates`.
 */
const clampWanted = (wanted: string, latest: string): string =>
  compareSegments(parseSegments(wanted), parseSegments(latest)) > 0 ? latest : (
    wanted
  );

/**
 * Memoizes `pnpm view <name> versions` across the ESLint cap and every hold
 * cap in one `computeUpdates` run; both may consult the same package.
 */
export const createVersionFetcher = (
  cwd: string,
  pnpmRunner: PnpmRunner
): VersionFetcher => {
  const versionCache = new Map<string, readonly string[]>();

  return (name) => {
    const cached = versionCache.get(name);

    if (cached !== undefined) return cached;

    const fetched = fetchPackageVersions(name, cwd, pnpmRunner);

    versionCache.set(name, fetched);

    return fetched;
  };
};

export type AdjustEntryContext = {
  cooldown: CooldownContext;
  getVersions: VersionFetcher;
  holds: ReadonlyMap<string, string>;
  pkg: PackageJsonShape;
};

type AdjustEntryResult =
  | {kind: 'adjusted'; value: Adjusted}
  | {kind: 'dropped'}
  | {kind: 'skipped'; value: SkippedEntry};

/**
 * Runs one outdated entry through the ESLint cap, config version hold, and
 * release-age cooldown, in that order, producing either an adjusted Wave
 * A/B candidate, a skipped entry (with reason), or a silent drop.
 */
export const adjustOutdatedEntry = (
  entry: OutdatedEntry,
  context: AdjustEntryContext
): AdjustEntryResult => {
  const {cooldown, getVersions, holds, pkg} = context;
  const eslintDecision = applyEslintCap(entry, getVersions);

  if (eslintDecision.kind === 'drop') return {kind: 'dropped'};

  const eslintLatest =
    eslintDecision.kind === 'rewrite' ? eslintDecision.latest : entry.latest;

  // Config version hold, applied after the ESLint cap so a held eslint is
  // capped by both. A held package that has nothing left to offer is dropped
  // and surfaced as `reason: held` so the maintainer sees the active hold.
  const holdDecision = applyHoldCap(
    {current: entry.current, latest: eslintLatest, name: entry.name},
    holds,
    getVersions
  );

  if (holdDecision.kind === 'drop') {
    return {
      kind: 'skipped',
      value: {
        current: entry.current,
        latest: eslintLatest,
        name: entry.name,
        reason: 'held',
      },
    };
  }

  const effectiveLatest =
    holdDecision.kind === 'rewrite' ? holdDecision.latest : eslintLatest;

  const cooled = applyCooldown({
    context: cooldown,
    current: entry.current,
    latest: effectiveLatest,
    name: entry.name,
  });

  if (cooled.kind !== 'ok') {
    return {
      kind: 'skipped',
      value: {
        current: entry.current,
        latest: effectiveLatest,
        name: entry.name,
        reason:
          cooled.kind === 'cooldown' ?
            'release-age-cooldown'
          : 'release-age-unresolved',
      },
    };
  }

  const cooledLatest = cooled.latest;
  const kind = classifyKind(entry.current, cooledLatest);

  if (kind === 'patch' && entry.current === cooledLatest) {
    // Already up to date after cap rewrite. Defensive; applyEslintCap's
    // drop branch already handles "already on highest 9.x", but a
    // best-of belt-and-suspenders guard for non-eslint paths.
    return {kind: 'dropped'};
  }

  return {
    kind: 'adjusted',
    value: {
      current: entry.current,
      group: resolveGroup(entry.name),
      is_pinned: isPinnedSpec(lookupSpec(pkg, entry.name)),
      kind,
      latest: cooledLatest,
      name: entry.name,
      wanted: clampWanted(entry.wanted, cooledLatest),
    },
  };
};
