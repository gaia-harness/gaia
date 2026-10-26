import {STATE_FILE_RELATIVE} from './init/util/state.js';

/**
 * Paths GAIA's own tooling writes on first use, so a fresh tree lacks them and
 * no ignore file names them: `gaia init` writes its resume cursor, and the wiki
 * maintenance passes write their audit reports under `wiki/meta/`. Only the
 * folder is listed: a report's name varies, so a cited file under it is still
 * a claim that the file exists.
 *
 * The one list every path-existence check reads (the fitness path rules and
 * the wiki dead-path scan), so a citation of one is never dead to one check
 * and live to another. It sits at the top of `src/` because `wiki/` must not
 * import `fitness/`.
 */
export const TOOLING_PATHS: ReadonlySet<string> = new Set([
  STATE_FILE_RELATIVE,
  'wiki/meta',
]);
