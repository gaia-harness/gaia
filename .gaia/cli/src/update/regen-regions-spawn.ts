import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {structuredError} from '../stderr.js';
import {execGaiaGitRaw} from '../util/git-env.js';
import {porcelainZPaths} from '../util/git-status.js';
import {isPlainObject} from './regen-regions-declaration.js';
import type {ParsedDeclaration} from './regen-regions-declaration.js';
import {isInsideScope} from './regen-regions-scope.js';
import type {KilledCause, RegenRegionsReport} from './regen-regions-types.js';

type GitStatus = {
  /** Root-relative, the same frame every other path in the report uses. */
  inside: string[];
  /** Changed paths that lie above `root`, kept in top-level frame. */
  outside: string[];
};

/**
 * `root`'s own path relative to the repository top level, with a trailing
 * slash, and empty when the two coincide (the ordinary case, and the only one
 * `--root .` at a repository root produces). `null` when git cannot answer.
 *
 * Resolved once per run rather than per status call. It is a property of
 * `--root`, which no region can change: it cannot differ between the before
 * and after snapshots, and it cannot differ between regions, so deriving it at
 * each of the two calls per region spawned a second git process every time for
 * an answer already known.
 */
export const resolveRepoPrefix = (root: string): null | string => {
  try {
    return execGaiaGitRaw(['rev-parse', '--show-prefix'], root).replace(
      /\r?\n$/u,
      ''
    );
  } catch {
    return null;
  }
};

/**
 * Whole-root `git status --porcelain -z` path list. `null` when git is
 * unavailable or `root` is not a repository, so the caller can degrade
 * cleanly rather than failing.
 *
 * `-z` is load-bearing, not a formatting preference: `porcelainZPaths` states
 * why, and parsing the records it returns is its job rather than this one's.
 *
 * Every record git returns is relative to the repository TOP LEVEL, never to
 * `root`, and the two differ whenever a GAIA project sits inside a larger
 * repository. Rebasing them onto `root` is what keeps the caller's comparisons
 * against the declared paths and the snapshot scope, both root-relative,
 * meaningful; without it every one of the region's own legitimate writes fails
 * to match and is reported to the adopter as an out-of-scope write.
 */
export const gitStatusPaths = (
  root: string,
  prefix: null | string
): GitStatus | null => {
  // `null` means git could not answer `--show-prefix` for this root, which is
  // the same condition that stops `git status` answering, so there is nothing
  // to gain by spawning it. The caller reports the delta unavailable.
  if (prefix === null) return null;

  try {
    // Raw, never trimmed: `porcelainZPaths` reads the status columns
    // positionally, and the ` M path` shape leads with one.
    const paths = porcelainZPaths(
      execGaiaGitRaw(['status', '--porcelain', '-z'], root)
    );

    if (prefix === '') return {inside: paths, outside: []};

    const inside: string[] = [];
    const outside: string[] = [];

    paths.forEach((changedPath) => {
      if (changedPath.startsWith(prefix)) {
        inside.push(changedPath.slice(prefix.length));

        return;
      }

      outside.push(changedPath);
    });

    return {inside, outside};
  } catch {
    return null;
  }
};

type SpawnOutcome =
  | {
      cause: KilledCause;
      kind: 'killed';
      message: string;
      ok: false;
      signal: string;
    }
  | {kind: 'exit'; message: string; ok: false; status: number}
  | {kind: 'spawn'; message: string; ok: false}
  | {ok: true};

/** Reads one field off a thrown value without asserting its shape. */
const errorField = (error: unknown, key: string): unknown =>
  isPlainObject(error) ? error[key] : undefined;

/**
 * Which of the three ways a killed child died. All three arrive identically
 * otherwise, `signal: 'SIGTERM'` and no status, so without this an adopter
 * whose program legitimately runs past the time bound, one that legitimately
 * says more than the output bound, and one an operator killed by hand all read
 * the same and none of them names GAIA's own ceiling as the reason.
 *
 * The codes are Node's, observed on the sync spawn path: a `timeout` kill
 * surfaces `ETIMEDOUT` and a `maxBuffer` overflow `ENOBUFS`, each on both the
 * thrown error and its nested `error`. Anything else came from outside this
 * process's own bounds.
 */
export const spawnFailureCause = (code: unknown): KilledCause => {
  if (code === 'ETIMEDOUT') return 'timeout';

  if (code === 'ENOBUFS') return 'maxBuffer';

  return 'external';
};

/**
 * Runaway guards on the regeneration program, not a performance budget.
 * Without them the spawn inherits Node's 1 MiB output buffer and no time
 * limit, so a program that merely talks a lot is killed mid-run, and one
 * that hangs hangs the whole update. The one shipped regeneration command is
 * nearly silent and fast; these bounds exist for adopter-authored ones.
 */
const SPAWN_MAX_BUFFER_BYTES = 32 * 1024 * 1024;
const SPAWN_TIMEOUT_MS = 5 * 60 * 1000;

/**
 * Step 6. Never runs through a shell, never a shell-interpreted string, and
 * never enables the shell option: the interpreter comes from the
 * declaration, so no shipped script's executable bit is load-bearing.
 */
export const trySpawn = (
  decl: ParsedDeclaration,
  root: string
): SpawnOutcome => {
  try {
    execFileSync(
      decl.interpreter,
      [path.resolve(root, decl.operand), ...decl.args],
      {
        cwd: root,
        encoding: 'utf8',
        maxBuffer: SPAWN_MAX_BUFFER_BYTES,
        // The child's stdout is never read, so discarding it outright leaves
        // stderr as the only stream that can reach the buffer bound at all,
        // and stderr is what carries the diagnostic this reports on failure.
        stdio: ['ignore', 'ignore', 'pipe'],
        timeout: SPAWN_TIMEOUT_MS,
      }
    );

    return {ok: true};
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = errorField(error, 'status');

    if (typeof status === 'number')
      return {kind: 'exit', message, ok: false, status};

    const signal = errorField(error, 'signal');

    // A killed child and an interpreter that never launched both arrive with
    // no exit status. Reporting them alike would tell the adopter the spawn
    // never happened when in fact it ran and was cut short, so the signal,
    // which only the killed case carries, is what separates them.
    return typeof signal === 'string' ?
        {
          cause: spawnFailureCause(errorField(error, 'code')),
          kind: 'killed',
          message,
          ok: false,
          signal,
        }
      : {kind: 'spawn', message, ok: false};
  }
};

type OutOfScopeInputs = {
  afterStatus: GitStatus | null;
  beforeStatus: GitStatus | null;
  decl: ParsedDeclaration;
  report: RegenRegionsReport;
  scopeDirs: ReadonlySet<string>;
};

/**
 * Whole-root half of step 5/7: anything git saw appear between the before
 * and after snapshots that isn't a declared path and isn't already inside
 * the (already-swept) snapshot scope is an out-of-scope write with no
 * pre-image, so it is reported rather than reverted. Degrades cleanly (a
 * non-fatal stderr note, no effect on the report or the exit code) when git
 * is unavailable or the root is not a repository.
 */
export const reportOutOfScopeWrites = (inputs: OutOfScopeInputs): void => {
  const {afterStatus, beforeStatus, decl, report, scopeDirs} = inputs;

  if (beforeStatus === null || afterStatus === null) {
    structuredError({
      code: 'region_regen_git_delta_unavailable',
      message: `whole-root out-of-scope-write detection skipped for region '${decl.id}': git status is unavailable or the run's root is not a git repository`,
      regionId: decl.id,
      subcommand: 'update regen-regions',
    });

    return;
  }

  const beforeSet = new Set(beforeStatus.inside);
  const declaredSet = new Set(decl.paths);

  afterStatus.inside.forEach((changedPath) => {
    if (
      beforeSet.has(changedPath) ||
      declaredSet.has(changedPath) ||
      isInsideScope(changedPath, scopeDirs)
    )
      return;

    report.confined.push({
      action: 'reported',
      path: changedPath,
      regionId: decl.id,
    });
  });

  const beforeOutside = new Set(beforeStatus.outside);
  const newOutside = afterStatus.outside.filter(
    (changedPath) => !beforeOutside.has(changedPath)
  );

  if (newOutside.length === 0) return;

  // Above the run's own root, so it has no root-relative form and cannot join
  // `confined[]`, whose paths are root-relative by contract. It is still a
  // real write the region made, so it leaves by the same non-fatal channel
  // the git-unavailable case uses rather than being dropped.
  structuredError({
    code: 'region_regen_git_delta_out_of_root',
    message: `region '${decl.id}' changed ${newOutside.length} path(s) above the run's root, reported here because they have no root-relative form: ${newOutside.join(', ')}`,
    regionId: decl.id,
    subcommand: 'update regen-regions',
  });
};
