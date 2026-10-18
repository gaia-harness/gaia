/**
 * Hosts the field-aware verdict oracles the `/update-gaia` skill invokes:
 * `merge-package` for each `package.json`, `merge-workspace` for
 * `pnpm-workspace.yaml` and `merge-audit-ci` for `.gaia/audit-ci.yml`, plus
 * `lockfile-command` (which pnpm command the lockfile needs), the
 * `merge-region` oracle for a declared generated region inside an owned file,
 * and the `regen-regions` runner it invokes once masking confirms a declared
 * region's divergence is confined to its markers, to make the adopter's
 * post-merge region correct again. The skill hand-walks the per-file decision
 * table itself, so the router carries no generic whole-file merge command.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {lookupOwn} from '../util/argv.js';
import {run as runLockfileCommand} from './lockfile-command.js';
import {run as runMergeAuditCi} from './merge-audit-ci.js';
import {run as runMergePackage} from './merge-package.js';
import {run as runMergeRegion} from './merge-region.js';
import {run as runMergeWorkspace} from './merge-workspace.js';
import {run as runRegenRegions} from './regen-regions.js';

const HELP_TEXT = `Usage: gaia update <subcommand> [args]

  merge-package   --baseline <file> --latest <file> --current <file> [--deferred-baseline <key>=<file>]... [--json]
                                              Field-aware package.json verdict.
  merge-workspace --baseline <file> --latest <file> --current <file> [--deferred-baseline <key>=<file>]... [--json]
                                              Field-aware pnpm-workspace.yaml verdict.
  merge-audit-ci  --baseline <file> --latest <file> --current <file> [--deferred-baseline <key>=<file>]... [--json]
                                              Field-aware .gaia/audit-ci.yml verdict.
  lockfile-command --root <dir> [--ref <ref>] [--json]
                                              Prints dedupe, install or none for the lockfile.
  merge-region    --baseline <file> --latest <file> --current <file> --start-marker <text> --end-marker <text> [--json]
                                              Region-aware generated-region verdict.
  regen-regions   --manifest <path> --root <dir> [--backup-dir <dir>] [--conflicted <path>]... [--absent-path <path>]... [--skip-region <id>]... [--json]
                                              Regenerates declared generated regions via their shipped command.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  'lockfile-command': runLockfileCommand,
  'merge-audit-ci': runMergeAuditCi,
  'merge-package': runMergePackage,
  'merge-region': runMergeRegion,
  'merge-workspace': runMergeWorkspace,
  'regen-regions': runRegenRegions,
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
    const result = await handler(rest);

    return typeof result === 'number' ? result : EXIT_CODES.OK;
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown update subcommand: ${subcommand}`,
    subcommand: `update ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
