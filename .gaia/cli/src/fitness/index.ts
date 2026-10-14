/**
 * The `gaia fitness` namespace: a deterministic linter over the Claude
 * integration a project holds (`check`, `rules`), companions that read or
 * write around it (`inventory`, `builtins`, `apply`), and the report-card
 * renderer. The model layer lives in the /gaia-fitness playbook; everything
 * here is reproducible.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {lookupOwn} from '../util/argv.js';
import {run as runApply} from './apply.js';
import {run as runBuiltins} from './builtins.js';
import {run as runCheck} from './check.js';
import {run as runInventory} from './inventory.js';
import {run as runRenderCard} from './render-card.js';
import {run as runRules} from './rules-command.js';

const HELP_TEXT = `Usage: gaia fitness <subcommand> [args]

  check [--json] [--root DIR] [--scope adopter|all] [--fail-on LEVEL]
        [--enforce ID]... [--only ID]... [--config PATH]
                            Lint the Claude integration and print one report.
  rules [--json]            List every rule with its detection.
  inventory [--json] [--root DIR]
                            List memory, rules, wiki and CLAUDE.md stores.
  builtins [--json] [--root DIR]
                            Run the Claude Code built-in checks.
  apply --target PATH --proposal FILE --base-sha256 HEX|absent [--root DIR]
                            Write one reviewed fix to one file.
  render-card [--cols N]    Render the /gaia-fitness report card from report
                            JSON on stdin (width-aware ASCII).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  apply: runApply,
  builtins: runBuiltins,
  check: runCheck,
  inventory: runInventory,
  'render-card': runRenderCard,
  rules: runRules,
};

export const run = async (argv: readonly string[]): Promise<number> => {
  const subcommand = argv[0];
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const handler = lookupOwn(SUBCOMMAND_HANDLERS, subcommand);

  if (handler !== undefined) {
    return await handler(rest);
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown fitness subcommand: ${subcommand}`,
    subcommand: `fitness ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
