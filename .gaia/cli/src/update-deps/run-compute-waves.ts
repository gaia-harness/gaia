import {resolveGroupMembers} from './groups.js';
import {applyCooldown} from './run-compute-adjust.js';
import type {Adjusted, CooldownContext} from './run-compute-adjust.js';
import {
  classifyBucket,
  classifyKind,
  compareStrings,
  isPinnedSpec,
  lookupSpec,
  readInstalledVersion,
} from './run-outdated.js';
import type {PackageJsonShape} from './run-outdated.js';
import type {
  Kind,
  PnpmRunner,
  SkippedEntry,
  WaveAEntry,
  WaveBGroup,
} from './run-types.js';
import {applyHoldCap, fetchLatestVersion} from './run-version-caps.js';
import type {VersionFetcher} from './run-version-caps.js';
import {stripRange} from './version.js';

export type ExpandSiblingContext = {
  cooldown: CooldownContext;
  getVersions: VersionFetcher;
  holds: ReadonlyMap<string, string>;
  pkg: PackageJsonShape;
  pnpmRunner: PnpmRunner;
};

type ExpandSiblingResult =
  {kind: 'member'; value: Adjusted} | {kind: 'skipped'; value: SkippedEntry};

/**
 * Companion-group sibling expansion for one sibling not flagged by `pnpm
 * outdated`: resolves its current/latest, runs it
 * through the same hold + cooldown pipeline as a trigger member, and reports
 * either a new group member or a skipped entry.
 */
const expandGroupSibling = (
  siblingName: string,
  group: string,
  context: ExpandSiblingContext
): ExpandSiblingResult => {
  const {cooldown, getVersions, holds, pkg, pnpmRunner} = context;
  const spec = lookupSpec(pkg, siblingName);

  // Prefer the version actually installed in node_modules; the
  // package.json spec (`^x`, `workspace:*`, a tag, …) is not a usable
  // version. Fall back to the spec floor only when node_modules has no
  // entry (e.g. dependencies not installed).
  const current =
    readInstalledVersion(cooldown.cwd, siblingName) ??
    (spec === undefined ? '' : stripRange(spec));
  const latest = fetchLatestVersion(siblingName, cooldown.cwd, pnpmRunner);

  if (latest === undefined) {
    // Registry call failed; omit from emit, record in skipped.
    return {
      kind: 'skipped',
      value: {
        current,
        latest: '',
        name: siblingName,
        reason: 'registry-unresolved',
      },
    };
  }

  // A held sibling is capped too, so group expansion never drags it above
  // its ceiling. A drop holds it at `current` (the group moves without it).
  const holdDecision = applyHoldCap(
    {current, latest, name: siblingName},
    holds,
    getVersions
  );

  if (holdDecision.kind === 'drop') {
    return {
      kind: 'skipped',
      value: {current, latest, name: siblingName, reason: 'held'},
    };
  }

  const heldLatest =
    holdDecision.kind === 'rewrite' ? holdDecision.latest : latest;

  const cooled = applyCooldown({
    context: cooldown,
    current,
    latest: heldLatest,
    name: siblingName,
  });

  if (cooled.kind !== 'ok') {
    return {
      kind: 'skipped',
      value: {
        current,
        latest: heldLatest,
        name: siblingName,
        reason:
          cooled.kind === 'cooldown' ?
            'release-age-cooldown'
          : 'release-age-unresolved',
      },
    };
  }

  const cooledLatest = cooled.latest;

  // If current === latest, kind is "patch" (no-op default per spec).
  const kind: Kind =
    current !== '' && current !== cooledLatest ?
      classifyKind(current, cooledLatest)
    : 'patch';

  return {
    kind: 'member',
    value: {
      current,
      group,
      is_pinned: isPinnedSpec(spec),
      kind,
      latest: cooledLatest,
      name: siblingName,
      wanted: cooledLatest,
    },
  };
};

type ExpandOneGroupArgs = {
  allGroupMembers: readonly string[];
  context: ExpandSiblingContext;
  group: string;
  members: Adjusted[];
};

/**
 * Sibling expansion for one non-singleton group: pulls in every group
 * member `pnpm outdated` did not flag, mutating `members` in place with
 * each accepted sibling and returning the ones that had to be skipped.
 */
const expandOneGroup = (args: ExpandOneGroupArgs): SkippedEntry[] => {
  const {allGroupMembers, context, group, members} = args;
  const alreadyInGroup = new Set(members.map((m) => m.name));
  const skipped: SkippedEntry[] = [];

  for (const siblingName of allGroupMembers) {
    if (!alreadyInGroup.has(siblingName)) {
      const outcome = expandGroupSibling(siblingName, group, context);

      if (outcome.kind === 'member') members.push(outcome.value);
      else skipped.push(outcome.value);
    }
  }

  return skipped;
};

/**
 * Companion-group sibling expansion. For every
 * non-singleton group with at least one outdated trigger member, scans
 * `allPackageNames` for group members `pnpm outdated` did not flag and pulls
 * each in via {@link expandOneGroup}, mutating `byGroup`'s member arrays in
 * place. Returns the sibling-expansion `skipped` entries.
 */
export const expandGroupSiblings = (
  byGroup: ReadonlyMap<string, Adjusted[]>,
  allPackageNames: readonly string[],
  context: ExpandSiblingContext
): SkippedEntry[] => {
  const skipped: SkippedEntry[] = [];

  for (const [group, members] of byGroup) {
    if (!group.startsWith('singleton:')) {
      skipped.push(
        ...expandOneGroup({
          allGroupMembers: resolveGroupMembers(group, allPackageNames),
          context,
          group,
          members,
        })
      );
    }
  }

  return skipped;
};

type RoutedGroup = {
  waveAEntries: readonly WaveAEntry[];
  waveBGroup: null | WaveBGroup;
};

/**
 * Routes one group's adjusted members into Wave A or Wave B: any major
 * member sends the whole group to Wave B (sorted, as one `WaveBGroup`);
 * otherwise every minor/patch member becomes its own Wave A row.
 */
export const routeGroupIntoWaves = (
  group: string,
  members: readonly Adjusted[],
  workspace: string | undefined
): RoutedGroup => {
  // Spread, never `workspace: undefined`: the app's entries keep no such key.
  const workspaceField = workspace === undefined ? {} : {workspace};
  const hasMajor = members.some((member) => member.kind === 'major');

  if (!hasMajor) {
    const waveAEntries: WaveAEntry[] = [];

    for (const member of members) {
      // Wave A entries can only be minor or patch; narrow the type.
      if (member.kind !== 'major') {
        waveAEntries.push({
          bucket: classifyBucket(member.current, member.latest),
          current: member.current,
          group: member.group,
          is_pinned: member.is_pinned,
          kind: member.kind,
          latest: member.latest,
          name: member.name,
          wanted: member.wanted,
          ...workspaceField,
        });
      }
    }

    return {waveAEntries, waveBGroup: null};
  }

  const sorted = members.toSorted((a, b) => compareStrings(a.name, b.name));

  return {
    waveAEntries: [],
    waveBGroup: {
      group,
      packages: sorted.map((member) => ({
        bucket: classifyBucket(member.current, member.latest),
        current: member.current,
        is_pinned: member.is_pinned,
        kind: member.kind,
        latest: member.latest,
        name: member.name,
        wanted: member.wanted,
        ...workspaceField,
      })),
    },
  };
};
