/**
 * Writes `sandbox_recommended` to `.gaia/project.json` (the committed project
 * config) through `updateProjectConfig`, creating the file when absent.
 *
 * A separate verb from `gaia init write-project-config` because that one
 * stamps init state, which a later `/setup-gaia` run must not do.
 *
 * Refuses (non-zero), and writes nothing, when the existing file is
 * malformed or the value is not `true` or `false`.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  ProjectConfigError,
  updateProjectConfig,
} from '../util/project-config-write.js';
import {resolveRepoRoot} from '../util/repo-root.js';

const SUBCOMMAND = 'setup write-sandbox-recommendation';

const HELP_TEXT = `Usage: gaia setup write-sandbox-recommendation <true|false>

  Write sandbox_recommended to .gaia/project.json (committed), merged onto the
  raw parsed config so a key a newer binary wrote survives. Creates the file
  when absent. Refuses if the file is malformed, or if the value is not
  true or false.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const firstArgument = argv[0];

  if (firstArgument === undefined || HELP_TOKENS.has(firstArgument)) {
    process.stdout.write(HELP_TEXT);

    return firstArgument === undefined ?
        EXIT_CODES.UNKNOWN_SUBCOMMAND
      : EXIT_CODES.OK;
  }

  const rest = argv.slice(1);

  if (rest.length > 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${rest[0]}`,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (firstArgument !== 'true' && firstArgument !== 'false') {
    structuredError({
      code: 'invalid_arguments',
      message: `unrecognized value: ${firstArgument}. Supported: true, false`,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const value = firstArgument === 'true';
  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: `${SUBCOMMAND.replace('setup ', 'gaia setup ')} must run inside a git repository`,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  try {
    updateProjectConfig(repoRoot, {sandbox_recommended: value});
  } catch (error) {
    if (error instanceof ProjectConfigError && error.kind === 'malformed') {
      structuredError({
        code: 'config_malformed',
        message: error.message,
        subcommand: SUBCOMMAND,
      });

      return EXIT_CODES.CONFIG_INVALID;
    }

    structuredError({
      code: 'project_config_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }

  process.stdout.write(`${JSON.stringify({sandbox_recommended: value})}\n`);

  return EXIT_CODES.OK;
};
