import {structuredError} from '../stderr.js';
import {takeNonFlagValue} from '../util/argv.js';
import {resolveWebTarget} from '../util/package-target.js';
import type {PackageTarget} from '../util/package-target.js';

/** Argv with `--package <name>` removed, and the name it carried. */
export type SplitArgv = {argv: string[]; packageName: string | undefined};

type ResolvedTarget = Extract<PackageTarget, {ok: true}>;

/**
 * Pull `--package <name>` out of argv so each command's own flag parser never
 * sees it. Reports a missing value as a usage error and returns `undefined`.
 */
export const splitPackageFlag = (
  rawArgv: readonly string[],
  subcommand: string
): SplitArgv | undefined => {
  const argv: string[] = [];
  let packageName: string | undefined;

  for (let index = 0; index < rawArgv.length; index += 1) {
    const token = rawArgv[index] as string;

    if (token === '--package') {
      const taken = takeNonFlagValue(rawArgv, index + 1, '--package');

      if (!taken.ok) {
        structuredError({
          code: 'invalid_arguments',
          message: taken.message,
          subcommand,
        });

        return undefined;
      }
      packageName = taken.value;
      index += 1;
    } else {
      argv.push(token);
    }
  }

  return {argv, packageName};
};

/**
 * The web package a command writes into, or `undefined` after reporting the
 * registry, descriptor or selection failure. Callers return `CONFIG_INVALID`
 * on `undefined` before creating any file.
 */
export const resolveScaffoldTarget = (
  cwd: string,
  subcommand: string,
  packageName?: string
): ResolvedTarget | undefined => {
  const target = resolveWebTarget(cwd, packageName);

  if (!target.ok) {
    structuredError({
      code: 'gaia_packages',
      message: target.message,
      subcommand,
    });

    return undefined;
  }

  return target;
};
