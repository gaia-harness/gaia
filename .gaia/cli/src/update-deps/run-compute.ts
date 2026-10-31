import path from 'node:path';
import {resolvePackageTarget} from '../util/package-target.js';
import {
  collectSnoozedGroups,
  computeActionableCount,
  loadDeclines,
  totalCount,
} from './declines.js';
import {
  adjustOutdatedEntry,
  createVersionFetcher,
} from './run-compute-adjust.js';
import type {
  Adjusted,
  AdjustEntryContext,
  ComputeOptions,
  CooldownContext,
} from './run-compute-adjust.js';
import {expandGroupSiblings, routeGroupIntoWaves} from './run-compute-waves.js';
import type {ExpandSiblingContext} from './run-compute-waves.js';
import {
  compareStrings,
  defaultPnpmRunner,
  parseOutdated,
  readPackageJson,
  readUpdateDepsHolds,
} from './run-outdated.js';
import type {OutdatedEntry, PackageJsonShape} from './run-outdated.js';
import {
  readMinimumReleaseAge,
  readMinimumReleaseAgeExclude,
} from './run-release-age.js';
import type {
  PnpmRunner,
  SkippedEntry,
  UpdatesPayload,
  WaveAEntry,
  WaveBGroup,
} from './run-types.js';
import {readCliWorkspaceMember} from './workspace-member.js';

/**
 * Discovers outdated packages via `pnpm outdated --json`. `pnpm outdated`
 * exits 0 (nothing outdated) or 1 (packages outdated) on a healthy run; any
 * other status, including the null status of a failed spawn, means pnpm
 * itself failed, so parsing its (likely empty) stdout would masquerade as
 * "everything up to date" — throw instead.
 */
const discoverOutdated = (
  cwd: string,
  pnpmRunner: PnpmRunner
): readonly OutdatedEntry[] => {
  const result = pnpmRunner(['outdated', '--json'], {cwd});

  if (result.status !== 0 && result.status !== 1) {
    throw new Error(
      `pnpm outdated failed (exit ${result.status ?? 'null'}): ${result.stderr.trim()}`
    );
  }

  return parseOutdated(result.stdout);
};

const mergeManifestSection = (
  rootSection: Readonly<Record<string, string>> | undefined,
  packageSection: Readonly<Record<string, string>> | undefined
): Readonly<Record<string, string>> => ({...rootSection, ...packageSection});

/**
 * One view over both manifests for spec lookup and sibling expansion; the
 * package's declaration wins when a name is declared in both.
 */
const mergeManifests = (
  rootPackage: PackageJsonShape,
  pkg: PackageJsonShape
): PackageJsonShape => ({
  dependencies: mergeManifestSection(
    rootPackage.dependencies,
    pkg.dependencies
  ),
  devDependencies: mergeManifestSection(
    rootPackage.devDependencies,
    pkg.devDependencies
  ),
  optionalDependencies: mergeManifestSection(
    rootPackage.optionalDependencies,
    pkg.optionalDependencies
  ),
  peerDependencies: mergeManifestSection(
    rootPackage.peerDependencies,
    pkg.peerDependencies
  ),
});

type WorkspaceWaves = {
  skipped: SkippedEntry[];
  waveA: WaveAEntry[];
  waveB: WaveBGroup[];
};

/**
 * Adjusts one workspace's outdated entries, groups them, expands companion
 * siblings from that workspace's manifest and routes the groups into the
 * waves. `workspace` tags every resulting entry; undefined leaves them bare.
 */
const buildWorkspaceWaves = (args: {
  entries: readonly OutdatedEntry[];
  expandContext: ExpandSiblingContext;
  workspace: string | undefined;
}): WorkspaceWaves => {
  const {entries, expandContext, workspace} = args;
  const {cooldown, getVersions, holds, pkg} = expandContext;
  const adjustContext: AdjustEntryContext = {cooldown, getVersions, holds, pkg};
  const adjusted: Adjusted[] = [];
  const skipped: SkippedEntry[] = [];

  for (const entry of entries) {
    const outcome = adjustOutdatedEntry(entry, adjustContext);

    if (outcome.kind === 'adjusted') adjusted.push(outcome.value);
    else if (outcome.kind === 'skipped') skipped.push(outcome.value);
  }

  // Bucket by group. A group lands in Wave B if any member is major;
  // otherwise every member becomes a Wave A row (singletons stay
  // singletons, but companion groups stay grouped; we expose them as
  // separate Wave A rows since Wave A is batched into one install anyway).
  const byGroup = new Map<string, Adjusted[]>();

  for (const entry of adjusted) {
    const list = byGroup.get(entry.group);

    if (list === undefined) byGroup.set(entry.group, [entry]);
    else list.push(entry);
  }

  // Companion-group sibling expansion.
  // For every non-singleton group with at least one outdated trigger member,
  // scan package.json for ALL members of that group and pull in any that
  // were not flagged by `pnpm outdated`. Fetch their `latest` via
  // `pnpm view <name> version`. Failures → `skipped` with
  // `reason: "registry-unresolved"`.
  const allPackageNames = Object.keys({
    ...pkg.dependencies,
    ...pkg.devDependencies,
    ...pkg.optionalDependencies,
    ...pkg.peerDependencies,
  });

  skipped.push(...expandGroupSiblings(byGroup, allPackageNames, expandContext));

  const waveA: WaveAEntry[] = [];
  const waveB: WaveBGroup[] = [];

  for (const [group, members] of byGroup) {
    const routed = routeGroupIntoWaves(group, members, workspace);

    waveA.push(...routed.waveAEntries);
    if (routed.waveBGroup !== null) waveB.push(routed.waveBGroup);
  }

  return {skipped, waveA, waveB};
};

export const computeUpdates = (options: ComputeOptions): UpdatesPayload => {
  const pnpmRunner = options.pnpmRunner ?? defaultPnpmRunner;
  // App dependencies, their installed versions, and `pnpm outdated` live in
  // the frontend package; the committed hold map and the release-age setting
  // stay at the repo root, so the two directories are resolved separately.
  const target = resolvePackageTarget(options.cwd);

  if (!target.ok) {
    throw new Error(target.message);
  }
  const {packageDir, packagePath, repoRoot} = target;
  const packageManifest = readPackageJson(packageDir);
  const rootPackage =
    packagePath === '.' ? packageManifest : readPackageJson(repoRoot);
  // `pnpm outdated` scopes to the project it runs in, so the harness
  // dependencies declared only in the root manifest need their own run. An
  // entry both manifests declare is listed once, from the package.
  const packageOutdated = discoverOutdated(packageDir, pnpmRunner);
  const raw =
    packagePath === '.' ? packageOutdated : (
      [
        ...packageOutdated,
        ...discoverOutdated(repoRoot, pnpmRunner).filter(
          (rootEntry) =>
            !packageOutdated.some((entry) => entry.name === rootEntry.name)
        ),
      ]
    );
  const pkg =
    packagePath === '.' ? packageManifest : (
      mergeManifests(rootPackage, packageManifest)
    );

  // Release-age cooldown context; disabled (no registry calls) when the
  // setting is unset, preserving the prior behaviour for adopters who do
  // not use it.
  const now = (options.now ?? (() => new Date()))();
  const minimumReleaseAgeMinutes = readMinimumReleaseAge(repoRoot);
  const cooldown: CooldownContext = {
    cooldownCutoffMs: now.getTime() - minimumReleaseAgeMinutes * 60_000,
    cwd: packageDir,
    minimumReleaseAgeExcludes: readMinimumReleaseAgeExclude(repoRoot),
    minimumReleaseAgeMinutes,
    pnpmRunner,
  };

  const holds = readUpdateDepsHolds(rootPackage);
  const appWaves = buildWorkspaceWaves({
    entries: raw,
    expandContext: {
      cooldown,
      getVersions: createVersionFetcher(packageDir, pnpmRunner),
      holds,
      pkg,
      pnpmRunner,
    },
    workspace: undefined,
  });
  const skipped: SkippedEntry[] = [...appWaves.skipped];
  const waveA: WaveAEntry[] = [...appWaves.waveA];
  const waveB: WaveBGroup[] = [...appWaves.waveB];

  // `pnpm outdated` never reports the CLI workspace member from the app, so it
  // gets its own pass, absent on an adopter tree. It stays a separate pipeline
  // because a companion group is built from one manifest and applied with one
  // `pnpm add`: a group must never mix members of two workspaces.
  const cliMember = readCliWorkspaceMember(repoRoot);

  if (cliMember !== null) {
    const memberDirectory = path.join(repoRoot, cliMember);
    const memberWaves = buildWorkspaceWaves({
      entries: discoverOutdated(memberDirectory, pnpmRunner),
      expandContext: {
        cooldown: {...cooldown, cwd: memberDirectory},
        getVersions: createVersionFetcher(memberDirectory, pnpmRunner),
        holds,
        pkg: readPackageJson(memberDirectory),
        pnpmRunner,
      },
      workspace: cliMember,
    });

    skipped.push(...memberWaves.skipped);
    waveA.push(...memberWaves.waveA);
    waveB.push(...memberWaves.waveB);
  }

  // Stable, alphabetical ordering for both waves.
  waveA.sort((a, b) => compareStrings(a.name, b.name));
  waveB.sort((a, b) => compareStrings(a.group, b.group));

  // The waves always carry every outstanding package: nothing here gates the
  // apply set, so the interactive preview can still refresh a snoozed group on
  // "update all". Snooze state is surfaced two ways off the same ledger read: `actionable_count` subtracts snoozed groups for
  // the statusline, and `snoozed` names them per-group so the preview can mark
  // and default-skip them. With no ledger, `actionable_count` equals
  // `total_count` and `snoozed` is empty.
  const countable = {wave_a: waveA, wave_b: waveB};
  const declines = loadDeclines(options.cwd);

  return {
    actionable_count: computeActionableCount(countable, declines, now),
    generated_at: now.toISOString(),
    schema_version: 1,
    skipped,
    snoozed: collectSnoozedGroups(countable, declines, now),
    total_count: totalCount(countable),
    wave_a: waveA,
    wave_b: waveB,
  };
};
