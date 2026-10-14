import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

/** Placeholder until the apply subcommand lands. */
export const run = (_args: readonly string[]): number => {
  structuredError({
    code: 'not_implemented',
    message: 'gaia fitness apply is not implemented yet',
    subcommand: 'fitness apply',
  });

  return EXIT_CODES.COULD_NOT_RUN;
};
