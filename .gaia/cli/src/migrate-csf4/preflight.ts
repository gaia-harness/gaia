import {execGaiaGitRaw} from '../util/git-env.js';
import {porcelainZPaths} from '../util/git-status.js';
import {gitZArgs} from '../util/git-z.js';

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

/** Every uncommitted path in the tree: staged, unstaged and untracked. */
export const dirtyTreePaths = (repoRoot: string): string[] =>
  statusPaths(repoRoot, []);

/**
 * The write-set paths that are untracked or differ from `HEAD`. A path outside
 * the write set is never read, so an update merge's uncommitted files pass.
 */
export const dirtyWriteSetPaths = (
  repoRoot: string,
  writeSet: readonly string[]
): string[] => {
  if (writeSet.length === 0) return [];
  const changed = new Set(statusPaths(repoRoot, writeSet));

  return writeSet.filter(
    (entry) => changed.has(entry) || !isTracked(repoRoot, entry)
  );
};
