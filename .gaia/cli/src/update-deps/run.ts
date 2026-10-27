/**
 * `gaia update-deps run --emit-updates <path>` handler.
 *
 * Discovers and groups the outdated packages for the /update-deps skill.
 *
 * Phase 1: Discover via `pnpm outdated --json`. ESLint 9.x cap rewrites
 *          a `latest >= 10.x` to the highest available `9.x`; if already
 *          on the highest 9.x, the entry is dropped silently. A config version
 *          hold (`gaia.updateDepsHold` in package.json) then caps each held
 *          package to its ceiling line, dropping it (`reason: held`) when
 *          nothing on that line beats the installed version. A release-age
 *          cooldown then caps each target to the newest version that has
 *          cleared `minimumReleaseAge` (from `pnpm-workspace.yaml`); a target
 *          with no aged upgrade is recorded as `skipped`.
 * Phase 2: Map each outdated package to its companion group via
 *          `groups.ts`. Packages with no rule become `singleton:<name>`.
 * Phase 3: Classify each group: any major bump → Wave B (per-group),
 *          else Wave A (batched). Groups with one major member pull all
 *          outdated siblings along; so the group moves together.
 *
 * Output: a JSON payload at the path passed to `--emit-updates`,
 * mirrored as a type below.
 */
import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {computeUpdates} from './run-compute.js';
import type {PnpmRunner, UpdatesPayload} from './run-types.js';

export {resolveGroup} from './groups.js';

export {computeUpdates} from './run-compute.js';

export {classifyBucket} from './run-outdated.js';

export {classifyKind} from './run-outdated.js';

export {fetchVersionTimes} from './run-release-age.js';

export {readMinimumReleaseAge} from './run-release-age.js';

export type {PnpmResult} from './run-types.js';

export type {PnpmRunner} from './run-types.js';

const HELP_TEXT = `Usage: gaia update-deps run --emit-updates <path>

  Discover outdated packages via \`pnpm outdated --json\`, classify each
  into Wave A (minor/patch, batched) or Wave B (major, per-group), and
  write the result as JSON to <path>. Used by the /update-deps skill to
  discover and group the updates before the LLM-driven upgrade.

  --emit-updates <path>   Required. JSON file to write. Parent dirs are
                          created on demand.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

// ---------- argv parsing ----------

type ParsedArgs = {
  emitUpdates: string;
};

type ParseError = {error: string};

const parseArgs = (argv: readonly string[]): ParsedArgs | ParseError => {
  let emitUpdates: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--emit-updates') {
      const value = argv[index + 1];

      if (value === undefined || value.length === 0) {
        return {error: '--emit-updates requires a path'};
      }

      emitUpdates = value;
      index += 1;
    } else {
      return {error: `unknown flag: ${token}`};
    }
  }

  if (emitUpdates === undefined) {
    return {error: '--emit-updates is required'};
  }

  return {emitUpdates};
};

// ---------- runner ----------

export type RunOptions = {
  cwd?: string;
  now?: () => Date;
  pnpmRunner?: PnpmRunner;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }
  }

  const parsed = parseArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'update-deps run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  try {
    const cwd = options.cwd ?? process.cwd();
    const payload = computeUpdates({
      cwd,
      now: options.now,
      pnpmRunner: options.pnpmRunner,
    });
    const stamped: UpdatesPayload = payload;

    const outPath =
      path.isAbsolute(parsed.emitUpdates) ?
        parsed.emitUpdates
      : path.join(cwd, parsed.emitUpdates);
    mkdirSync(path.dirname(outPath), {recursive: true});
    writeFileSync(outPath, `${JSON.stringify(stamped, null, 2)}\n`, 'utf8');

    return EXIT_CODES.OK;
  } catch (error) {
    structuredError({
      code: 'update_deps_run_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'update-deps run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
};
