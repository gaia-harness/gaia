import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {loadTypescript} from '../util/load-typescript.js';
import {parseMigrateArgs} from './args.js';
import * as repairs from './repairs/index.js';
import {runTool} from './run-tool.js';
import {runMigrateCsf4} from './run.js';

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const HELP_TEXT = `Usage: gaia migrate-csf4 [--update-merge] [--json]

  Convert this project's CSF3 stories to CSF Next, repair what the upstream
  converter misses, then report per story file whether it loads and passes.

  --update-merge  Run on the uncommitted tree an update merge left behind.
  --json          Print the report as JSON.
`;

/** `gaia migrate-csf4 [--update-merge] [--json]` */
export const run = (argv: string[]): number => {
  if (argv.some((token) => HELP_TOKENS.has(token))) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseMigrateArgs(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'migrate-csf4',
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }

  return runMigrateCsf4(parsed.options, {
    cwd: process.cwd(),
    loadTypescript,
    repairs: {
      capturePreCodemodFacts: repairs.capturePreCodemodFacts,
      classifyStoryFile: repairs.classifyStoryFile,
      ensurePreviewImportsSubpath: repairs.ensurePreviewImportsSubpath,
      mainAddonSpecifiers: repairs.mainAddonSpecifiers,
      repairStoryFile: repairs.repairStoryFile,
      restoreLeadingComment: repairs.restoreLeadingComment,
      rewirePreview: repairs.rewirePreview,
      setTestSyntaxFlag: repairs.setTestSyntaxFlag,
    },
    runCommand: runTool,
    writeErr: (text) => process.stderr.write(text),
    writeOut: (text) => process.stdout.write(text),
  });
};
