/**
 * `gaia update crossing preflight`: the read-only checks the crossing note runs
 * before it moves anything. One stop reason per condition, checked in a fixed
 * order, and no check changes the tree, the index, HEAD or a ref.
 *
 * The resume arm exists because an interrupted crossing leaves the app moved
 * and the manifest still keyed on the old root, on the update branch with
 * uncommitted work. That state passes without the clean-tree and
 * default-branch stops, and the note then re-runs every later verb, which are
 * idempotent.
 */
import {existsSync, readdirSync, realpathSync} from 'node:fs';
import path from 'node:path';
import {execGaiaGit} from '../util/git-env.js';
import {
  DESCRIPTOR_FILE,
  done,
  LEGACY_PACKAGE_NAME,
  LEGACY_PACKAGE_ROOT,
  LEGACY_PREFIX,
  MANIFEST_FILE,
  manifestKeys,
  NEW_PACKAGE_NAME,
  NEW_PACKAGE_ROOT,
  readRegistry,
  readTextIfPresent,
  stop,
  topLevelOf,
} from './crossing-shared.js';
import type {Outcome} from './crossing-shared.js';

const NOTEBOOK_DEPTH = 5;
const NEXT_STEPS = {
  'both-trees-present':
    'move or remove one of the two app directories so only one holds the app, then re-run the note',
  'default-branch-behind':
    'check out the default branch and update it until it matches origin, then re-run the note',
  'dirty-tree':
    'commit or set aside the uncommitted changes, then re-run the note',
  'linked-worktree':
    'run the note from the main checkout, not a linked worktree',
  'member-named-web':
    'rename the registry member named web, because the crossing renames the app member to that name, then re-run the note',
  'not-root-launch':
    'start the session at the repository root and re-run the note',
  'plan-in-execution':
    'finish or close the executing plan by removing its RUNNING file, then re-run the note',
  'registry-path':
    'correct .gaia/packages.json so exactly one member sits at the app path, then re-run the note',
} as const;

type Reason = keyof typeof NEXT_STEPS;

const git = (root: string, args: string[]): string | undefined => {
  try {
    return execGaiaGit(args, root);
  } catch {
    return undefined;
  }
};

const holdsApp = (directory: string): boolean =>
  existsSync(path.join(directory, 'package.json')) ||
  existsSync(path.join(directory, DESCRIPTOR_FILE));

const isResume = (root: string): boolean => {
  if (existsSync(path.join(root, LEGACY_PACKAGE_ROOT))) return false;
  if (!holdsApp(path.join(root, NEW_PACKAGE_ROOT))) return false;
  const manifest = readTextIfPresent(path.join(root, MANIFEST_FILE));
  const keys = manifest === undefined ? undefined : manifestKeys(manifest);

  return keys?.some((key) => key.startsWith(LEGACY_PREFIX)) ?? false;
};

const isLinkedWorktree = (root: string): boolean => {
  const gitDirectory = git(root, [
    'rev-parse',
    '--path-format=absolute',
    '--git-dir',
  ]);
  const commonDirectory = git(root, [
    'rev-parse',
    '--path-format=absolute',
    '--git-common-dir',
  ]);

  if (gitDirectory === undefined || commonDirectory === undefined) {
    return false;
  }

  return realpathSync(gitDirectory) !== realpathSync(commonDirectory);
};

const hasRunningPlan = (directory: string, depth = 0): boolean => {
  if (depth > NOTEBOOK_DEPTH) return false;
  let entries;

  try {
    entries = readdirSync(directory, {withFileTypes: true});
  } catch {
    return false;
  }

  return entries.some((entry) => {
    if (entry.isFile() && entry.name === 'RUNNING') return true;

    return (
      entry.isDirectory() &&
      hasRunningPlan(path.join(directory, entry.name), depth + 1)
    );
  });
};

const defaultBranch = (root: string): string => {
  const remoteHead = git(root, [
    'symbolic-ref',
    '--short',
    '-q',
    'refs/remotes/origin/HEAD',
  ]);

  const name = remoteHead?.replace(/^origin\//u, '');

  return name === undefined || name === '' ? 'main' : name;
};

/** Off the default branch, or not level with its origin ref when one exists. */
const isBehindDefault = (root: string): boolean => {
  const branch = defaultBranch(root);
  const current = git(root, ['symbolic-ref', '--short', '-q', 'HEAD']);

  if (current !== branch) return true;
  const origin = git(root, [
    'rev-parse',
    '--verify',
    '--quiet',
    `refs/remotes/origin/${branch}`,
  ]);

  return origin !== undefined && origin !== git(root, ['rev-parse', 'HEAD']);
};

/** The registry stop for the member layout, or undefined when it is workable. */
const registryReason = (root: string, resume: boolean): Reason | undefined => {
  const entries = readRegistry(root);

  if (entries === undefined) return 'registry-path';
  const accepted =
    resume ? [LEGACY_PACKAGE_ROOT, NEW_PACKAGE_ROOT] : [LEGACY_PACKAGE_ROOT];
  const appEntry = entries.find((entry) => accepted.includes(entry.path));

  if (appEntry === undefined) return 'registry-path';

  if (
    existsSync(path.join(root, LEGACY_PACKAGE_ROOT)) &&
    existsSync(path.join(root, NEW_PACKAGE_ROOT))
  ) {
    return 'both-trees-present';
  }

  const renamed = appEntry.name === LEGACY_PACKAGE_NAME;
  const collides = entries.some(
    (entry) => entry !== appEntry && entry.name === NEW_PACKAGE_NAME
  );

  return renamed && collides ? 'member-named-web' : undefined;
};

const failing = (
  root: string,
  workingDirectory: string
): Reason | undefined => {
  const resume = isResume(root);

  if (!resume && (git(root, ['status', '--porcelain']) ?? '') !== '') {
    return 'dirty-tree';
  }
  if (isLinkedWorktree(root)) return 'linked-worktree';
  if (realpathSync(workingDirectory) !== root) return 'not-root-launch';
  if (hasRunningPlan(path.join(root, '.notebook'))) return 'plan-in-execution';
  if (!resume && isBehindDefault(root)) return 'default-branch-behind';

  return registryReason(root, resume);
};

export const runPreflight = (workingDirectory: string): Outcome => {
  const root = topLevelOf(workingDirectory);

  if (root === undefined) {
    return stop('not-root-launch', NEXT_STEPS['not-root-launch']);
  }
  const reason = failing(root, workingDirectory);

  if (reason !== undefined) return stop(reason, NEXT_STEPS[reason]);

  return done([`CROSSING_PASS ${isResume(root) ? 'resume' : 'fresh'}`]);
};
