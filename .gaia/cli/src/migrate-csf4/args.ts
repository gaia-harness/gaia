import type {MigrateOptions} from './types.js';

export type ParsedArgs =
  {message: string; ok: false} | {ok: true; options: MigrateOptions};

export const parseMigrateArgs = (argv: readonly string[]): ParsedArgs => {
  const options: MigrateOptions = {json: false, updateMerge: false};

  for (const token of argv) {
    if (token === '--json') options.json = true;
    else if (token === '--update-merge') options.updateMerge = true;
    else return {message: `unknown flag: ${token}`, ok: false};
  }

  return {ok: true, options};
};
