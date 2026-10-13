/**
 * One-time relocation of the machine-local codify state from its earlier
 * directory name to `.gaia/local/codify/`. The state is the operator's real
 * decisions (declined candidates, the review that silences the nudge), so the
 * move renames and never deletes.
 */
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
} from 'node:fs';
import path from 'node:path';
import {structuredError} from '../stderr.js';
import {resolveMainWorktreeRoot, sameRealPath} from '../util/main-root.js';
import {resolveRepoRoot} from '../util/repo-root.js';

export type CodifyStateMove =
  | 'kept-new'
  | 'moved'
  | 'moved-except-v1-ledger'
  | 'none'
  | 'skipped-not-main-checkout';

const EARLIER_DIRECTORY = 'harden';
const CURRENT_DIRECTORY = 'codify';
const LEDGER_FILE = 'declines.json';

// A concurrent run that renamed first leaves these on the loser's rename.
const LOST_RACE_CODES = new Set(['EEXIST', 'ENOENT', 'ENOTEMPTY']);

const isLostRace = (error: unknown): boolean =>
  error instanceof Error &&
  'code' in error &&
  typeof error.code === 'string' &&
  LOST_RACE_CODES.has(error.code);

/**
 * True only when `cwd` is the main checkout: its own toplevel is the main
 * root the shared resolver derives. Any git failure reads as "not the main
 * checkout" so the move fails safe: a linked worktree's `.gaia/local` is a
 * symlink to the main checkout's, and a move from there would rename state
 * concurrent sessions still read.
 */
export const isMainCheckout = (cwd: string): boolean => {
  try {
    return sameRealPath(resolveRepoRoot(cwd), resolveMainWorktreeRoot(cwd));
  } catch {
    return false;
  }
};

// The earlier ledger format is unreadable to the current reader, and the
// migration prompt tells the adopter to delete it at its old path, so it must
// stay where that command looks.
const isVersionOneLedger = (ledgerPath: string): boolean => {
  try {
    const parsed: unknown = JSON.parse(readFileSync(ledgerPath, 'utf8'));

    return (
      typeof parsed === 'object' &&
      parsed !== null &&
      'version' in parsed &&
      parsed.version === 1
    );
  } catch {
    return false;
  }
};

/** One-time move of the earlier state directory to `.gaia/local/codify/`, main checkout only. Never deletes. */
export const relocateCodifyState = (
  repoRoot: string,
  cwd: string = process.cwd()
): CodifyStateMove => {
  const localDirectory = path.join(repoRoot, '.gaia', 'local');
  const earlierPath = path.join(localDirectory, EARLIER_DIRECTORY);
  const currentPath = path.join(localDirectory, CURRENT_DIRECTORY);

  // Both early returns touch nothing, so they run before the git spawn the
  // main-checkout check costs: the statusline refresher reaches this on every
  // refresh, long after the one move has happened.
  if (existsSync(currentPath)) return 'kept-new';
  if (!existsSync(earlierPath)) return 'none';
  if (!isMainCheckout(cwd)) return 'skipped-not-main-checkout';

  try {
    if (!isVersionOneLedger(path.join(earlierPath, LEDGER_FILE))) {
      renameSync(earlierPath, currentPath);

      return 'moved';
    }

    mkdirSync(currentPath);

    for (const entry of readdirSync(earlierPath)) {
      if (entry !== LEDGER_FILE) {
        renameSync(
          path.join(earlierPath, entry),
          path.join(currentPath, entry)
        );
      }
    }

    return 'moved-except-v1-ledger';
  } catch (error) {
    if (isLostRace(error)) return 'kept-new';

    throw error;
  }
};

/**
 * The repository root for `cwd`, after the one-time state move. Throws only
 * when `cwd` is not inside a repository; a failed move is reported on stderr
 * and the caller reads whichever state directory exists.
 */
export const resolveCodifyRoot = (cwd: string): string => {
  const repoRoot = resolveRepoRoot(cwd);

  try {
    relocateCodifyState(repoRoot, cwd);
  } catch (error) {
    structuredError({
      code: 'codify_state_move_failed',
      message: error instanceof Error ? error.message : String(error),
    });
  }

  return repoRoot;
};
