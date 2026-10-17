import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  seedEnvironmentFile,
  UNEXPECTED_EXIT,
} from '../util/seed-environment-file.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = `Usage: gaia init bootstrap-env

  Copy .env.example to .env in the frontend package root (frontend/) when
  .env does not yet exist. No-op when .env already exists or .env.example is
  absent.

  Exit codes:
    0  success (no stdout)
    1  unknown flag
    2  unexpected filesystem failure
    30 package registry could not resolve the frontend package root
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const STEP_NAME = 'bootstrap-env';

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [first] = argv;

  if (first !== undefined && HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  if (argv.length > 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${argv[0]}`,
      subcommand: 'init bootstrap-env',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const seeded = seedEnvironmentFile(cwd, 'init bootstrap-env');

  if (seeded !== EXIT_CODES.OK) return seeded;

  try {
    markStepCompleted(cwd, STEP_NAME);
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init bootstrap-env',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
