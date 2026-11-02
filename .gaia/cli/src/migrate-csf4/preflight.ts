import {execGaiaGitRaw} from '../util/git-env.js';
import {porcelainZPaths} from '../util/git-status.js';
import {gitZArgs, splitZStream} from '../util/git-z.js';

const statusPaths = (
  repoRoot: string,
  pathspecs: readonly string[]
): string[] =>
  porcelainZPaths(
    execGaiaGitRaw(
      gitZArgs('status', [
        '--porcelain',
        '--untracked-files=all',
        ...(pathspecs.length > 0 ?
          ['--', ...pathspecs.map((entry) => `:(literal)${entry}`)]
        : []),
      ]),
      repoRoot
    )
  );

const isTracked = (repoRoot: string, repoRelativePath: string): boolean => {
  try {
    execGaiaGitRaw(
      ['ls-files', '--error-unmatch', '--', `:(literal)${repoRelativePath}`],
      repoRoot
    );

    return true;
  } catch {
    return false;
  }
};

/** Staged renames as destination to origin, rename detection on. */
const stagedRenameSources = (repoRoot: string): Map<string, string> => {
  const records = splitZStream(
    execGaiaGitRaw(
      gitZArgs('diff', ['--cached', '-M', '--name-status']),
      repoRoot
    )
  );
  const sources = new Map<string, string>();

  for (let index = 0; index < records.length;) {
    const code = records[index] ?? '';

    if (code.startsWith('R')) {
      const origin = records[index + 1];
      const destination = records[index + 2];

      if (origin !== undefined && destination !== undefined) {
        sources.set(destination, origin);
      }
      index += 3;
    } else {
      index += 2;
    }
  }

  return sources;
};

const blobAtHead = (repoRoot: string, repoRelativePath: string): string => {
  try {
    return execGaiaGitRaw(
      ['rev-parse', '--verify', '--quiet', `HEAD:${repoRelativePath}`],
      repoRoot
    ).trim();
  } catch {
    return '';
  }
};

const blobOnDisk = (repoRoot: string, repoRelativePath: string): string => {
  try {
    return execGaiaGitRaw(
      ['hash-object', '--', repoRelativePath],
      repoRoot
    ).trim();
  } catch {
    return '';
  }
};

/** A staged rename whose content, on disk too, is its origin's content. */
const isPureRename = (
  repoRoot: string,
  renames: ReadonlyMap<string, string>,
  entry: string
): boolean => {
  const origin = renames.get(entry);

  if (origin === undefined) return false;
  const originBlob = blobAtHead(repoRoot, origin);

  return originBlob !== '' && originBlob === blobOnDisk(repoRoot, entry);
};

/** Every uncommitted path in the tree: staged, unstaged and untracked. */
export const dirtyTreePaths = (repoRoot: string): string[] =>
  statusPaths(repoRoot, []);

/**
 * The write-set paths that are untracked or differ from `HEAD`. A path outside
 * the write set is never read, so an update merge's uncommitted files pass.
 * A path that is a staged rename with its origin's exact content reads as
 * clean: the move changed where it lives, not what it holds.
 */
export const dirtyWriteSetPaths = (
  repoRoot: string,
  writeSet: readonly string[]
): string[] => {
  if (writeSet.length === 0) return [];
  const changed = new Set(statusPaths(repoRoot, writeSet));
  const renames = stagedRenameSources(repoRoot);

  return writeSet.filter(
    (entry) =>
      (changed.has(entry) || !isTracked(repoRoot, entry)) &&
      !isPureRename(repoRoot, renames, entry)
  );
};
