import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../../util/atomic-write.js';
import {resolveMainWorktreeRoot} from '../../util/main-root.js';
import {computeWikiState, readStateFile} from '../state.js';

const CACHE_RELATIVE_PATH = path.join(
  '.gaia',
  'local',
  'cache',
  'shared',
  'update-check.json'
);

/**
 * Mark the statusline refresher cache stale (`checkedAt: 0`) so the next render
 * recomputes `wikiDriftCount` from the post-land `wiki/.state.json`. Zeroing the
 * cached count instead would come back on the next refresher run. No-op when the
 * file is absent or not a JSON object; never throws.
 */
export const invalidateStatuslineCache = (repoRoot: string): void => {
  try {
    const cachePath = path.join(
      resolveMainWorktreeRoot(repoRoot),
      CACHE_RELATIVE_PATH
    );

    if (!existsSync(cachePath)) return;

    const parsed: unknown = JSON.parse(readFileSync(cachePath, 'utf8'));

    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed))
      return;

    atomicWriteFileSync(
      cachePath,
      `${JSON.stringify({...parsed, checkedAt: 0}, null, 2)}\n`
    );
  } catch {
    // Best-effort: a stale nudge is recoverable, a failed land is not.
  }
};

/**
 * Write the main checkout's current wiki drift into the statusline refresher
 * cache now, rather than waiting for the detached refresher the next render
 * starts. Writes `wikiDriftCount` from the same computation as `gaia wiki state`
 * and `wikiStateSha` from the state file, the pair the refresher writes, so its
 * TTL gate reads the cache as current. Every other key is kept. Returns the
 * count written, or null when the file is absent or not a JSON object (no cache
 * means no nudge is showing). Never throws.
 */
export const refreshWikiDriftInCache = (repoRoot: string): null | number => {
  try {
    const mainRoot = resolveMainWorktreeRoot(repoRoot);
    const cachePath = path.join(mainRoot, CACHE_RELATIVE_PATH);
    // An absent cache throws here and lands in the catch: no cache, no nudge.
    const parsed: unknown = JSON.parse(readFileSync(cachePath, 'utf8'));

    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed))
      return null;

    const driftCount = computeWikiState(mainRoot).drift_count;
    const stateSha =
      readStateFile(path.join(mainRoot, 'wiki', '.state.json'))
        ?.last_evaluated_sha ?? '';

    atomicWriteFileSync(
      cachePath,
      `${JSON.stringify({...parsed, wikiDriftCount: driftCount, wikiStateSha: stateSha}, null, 2)}\n`
    );

    return driftCount;
  } catch {
    return null;
  }
};
