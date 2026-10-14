import {takeNonFlagValue} from '../util/argv.js';
import {resolveRepoRoot} from '../util/repo-root.js';

/** The repo root for the current directory, or the directory itself outside a repo. */
export const defaultRoot = (): string => {
  try {
    return resolveRepoRoot(process.cwd());
  } catch {
    return process.cwd();
  }
};

export type RootArguments =
  {message: string; ok: false} | {ok: true; root: string | undefined};

/**
 * Parses the `--root <dir>` / `--json` argument shape shared by the read-only
 * subcommands. `--json` is accepted for symmetry with the other subcommands;
 * JSON is the only output format.
 */
export const parseRootArguments = (args: readonly string[]): RootArguments => {
  let root: string | undefined;
  let index = 0;

  while (index < args.length) {
    const flag = args[index] ?? '';

    index += 1;

    if (flag === '--root') {
      const taken = takeNonFlagValue(args, index, flag);

      if (!taken.ok) return {message: taken.message, ok: false};
      root = taken.value;
      index += 1;
    } else if (flag !== '--json') {
      return {message: `unknown argument: ${flag}`, ok: false};
    }
  }

  return {ok: true, root};
};
