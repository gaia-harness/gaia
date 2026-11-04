/**
 * The `/setup-gaia` per-machine `.env` step. A teammate's fresh clone has no
 * `apps/web/.env` (it is gitignored), and a Bash `cp` onto it is refused by the
 * project's `Edit(apps/web/.env)` deny, so the copy runs in this subprocess.
 * It writes no `.gaia/init-state.json`: that cursor is scaffold-time state,
 * and a clone that never ran `/gaia-init` would be left holding an untracked
 * file. Setup progress is recorded by the caller through `gaia setup
 * mark-step`; `/gaia-init` calls it unrecorded before its commit.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {seedEnvironmentFile} from '../util/seed-environment-file.js';

const HELP_TEXT = `Usage: gaia setup bootstrap-env

  Copy .env.example to .env in the web app package root (apps/web/) when
  .env does not yet exist. No-op when .env already exists or .env.example is
  absent. Records no progress; run \`gaia setup mark-step bootstrap-env\` after.

  Exit codes:
    0  success (no stdout)
    1  unknown flag
    2  unexpected filesystem failure
    30 package registry could not resolve the web app package root
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const SUBCOMMAND = 'setup bootstrap-env';

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
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return seedEnvironmentFile(options.cwd ?? process.cwd(), SUBCOMMAND);
};
