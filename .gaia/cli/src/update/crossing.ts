/**
 * Router for `gaia update crossing <verb>`: the deterministic steps of the
 * blocking migration note that moves the app to its new home. Each verb prints
 * machine lines the note reads and exits 0, or exits 3 after a
 * `CROSSING_STOP` line and a next step.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {runMove} from './crossing-move.js';
import {runPreflight} from './crossing-preflight.js';
import {parseRekeyArguments, runRekey} from './crossing-rekey.js';
import {runRoster} from './crossing-roster.js';
import type {Outcome} from './crossing-shared.js';

export const HELP_TEXT = `Usage: gaia update crossing <verb>

  preflight                                   Checks the tree may cross; changes nothing.
  move                                        Moves the app and finishes the registry, descriptor, name and workspace edits.
  rekey --baseline-tag <tag> [--extra-tag <tag>]...
                                              Writes rekeyed bundle trees and rewrites decision paths.
  roster                                      Brings .gaia/audit-ci.yml to the new layout.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const print = (outcome: Outcome): number => {
  if (outcome.lines.length > 0) {
    process.stdout.write(`${outcome.lines.join('\n')}\n`);
  }

  return outcome.exit;
};

const usageError = (verb: string, message: string): number => {
  structuredError({
    code: 'invalid_arguments',
    message,
    subcommand: `update crossing ${verb}`,
  });

  return EXIT_CODES.INVALID_ARGUMENTS;
};

export const run = (argv: readonly string[]): number => {
  const verb = argv[0];
  const rest = argv.slice(1);
  const workingDirectory = process.cwd();

  if (verb === undefined || HELP_TOKENS.has(verb)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  if (verb === 'rekey') {
    const parsed = parseRekeyArguments(rest);

    return parsed.ok ?
        print(runRekey(workingDirectory, parsed))
      : usageError(verb, parsed.message);
  }

  const bare = {
    move: runMove,
    preflight: runPreflight,
    roster: runRoster,
  } as const;

  if (verb === 'move' || verb === 'preflight' || verb === 'roster') {
    return rest.length > 0 ?
        usageError(verb, `${verb} takes no arguments`)
      : print(bare[verb](workingDirectory));
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown crossing verb: ${verb}`,
    subcommand: `update crossing ${verb}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
