import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

/** Placeholder until the builtins subcommand lands. */
export const run = (_args: readonly string[]): number => {
  structuredError({
    code: 'not_implemented',
    message: 'gaia fitness builtins is not implemented yet',
    subcommand: 'fitness builtins',
  });

  return EXIT_CODES.COULD_NOT_RUN;
};
