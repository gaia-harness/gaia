/**
 * `gaia setup check-admin --owner <o> --repo <r> [--json]` handler.
 *
 * Probes whether the authenticated user has admin permission on the
 * target repo. Returns a strict three-way `auth_status` enum so the
 * slash command can branch:
 *
 *   - `ok`              : gh auth + API both succeeded.
 *   - `unauthenticated` : gh auth status failed.
 *   - `api_error`       : auth ok but the repos API call failed.
 *
 * Contract: `admin: false` whenever `auth_status != "ok"`. Never
 * false-positive admin. Exits 0 for every probe outcome and 1 on a
 * usage error; `check-admin` is a query, not a gate. An `ok` answer is
 * also cached as `admin` in `.gaia/local/setup-state.json`.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveMainWorktreeRoot} from '../util/main-root.js';
import {runGhAsync} from '../util/run-process.js';
import {readStateFile, writeStateFile} from './util/state-file.js';
import type {SetupState} from './util/state-file.js';

const HELP_TEXT = `Usage: gaia setup check-admin --owner <o> --repo <r> [--json]

  Probe repo admin permission via \`gh\`. Returns admin: false for any
  non-ok auth status. Exits 0 for every probe outcome; exits 1 on a usage
  error.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type AuthStatus = 'api_error' | 'ok' | 'unauthenticated';

type CheckAdminOutput = {
  admin: boolean;
  auth_status: AuthStatus;
  error?: string;
};

type RunOptions = {
  cwd?: string;
};

const printHuman = (output: CheckAdminOutput): void => {
  process.stdout.write(
    `admin: ${String(output.admin)}\nauth_status: ${output.auth_status}\n`
  );
};

const printOutput = (output: CheckAdminOutput, json: boolean): void => {
  if (json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }
};

// Extracted out of `run` (kept its cognitive complexity under the frozen
// limit): the two-step gh probe, independent of --json/human printing.
const probeAdmin = async (
  owner: string,
  repo: string,
  cwd: string
): Promise<CheckAdminOutput> => {
  // Step 1: gh auth status.
  const authResult = await runGhAsync({args: ['auth', 'status'], cwd});

  if (!authResult.ok) {
    return {admin: false, auth_status: 'unauthenticated'};
  }

  // Step 2: gh api repos/<owner>/<repo> --jq .permissions.admin.
  const apiResult = await runGhAsync({
    args: ['api', `repos/${owner}/${repo}`, '--jq', '.permissions.admin'],
    cwd,
  });

  if (!apiResult.ok) {
    return {
      admin: false,
      auth_status: 'api_error',
      error: apiResult.stderr.trim(),
    };
  }

  const trimmed = apiResult.stdout.trim();

  return {admin: trimmed === 'true', auth_status: 'ok'};
};

// Only an ok probe is an answer: a failed one says nothing about permission, so
// it keeps whatever an earlier ok probe cached. Best-effort: the cache feeds a
// statusline nudge, so a missing repo or an unreadable state file never turns
// this query into a failure.
const cacheAdmin = (cwd: string, admin: boolean): void => {
  try {
    const mainRoot = resolveMainWorktreeRoot(cwd);
    const state: SetupState = readStateFile(mainRoot) ?? {
      completed_at: null,
      completed_steps: [],
      started_at: new Date().toISOString(),
      version: 1,
    };
    writeStateFile(mainRoot, {...state, admin});
  } catch {
    // The probe's answer still prints; only the cache is skipped.
  }
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  let json = false;
  let owner: string | undefined;
  let repo: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token !== undefined) {
      if (HELP_TOKENS.has(token)) {
        process.stdout.write(HELP_TEXT);

        return EXIT_CODES.OK;
      }

      if (token === '--json') {
        json = true;
      } else if (token === '--owner') {
        owner = argv[index + 1];
        index += 1;
      } else if (token === '--repo') {
        repo = argv[index + 1];
        index += 1;
      } else {
        structuredError({
          code: 'invalid_arguments',
          message: `unknown flag: ${token}`,
          subcommand: 'setup check-admin',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
    }
  }

  if (owner === undefined || repo === undefined) {
    structuredError({
      code: 'missing_required_arg',
      message: 'check-admin requires --owner <o> --repo <r>',
      subcommand: 'setup check-admin',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const output = await probeAdmin(owner, repo, cwd);

  if (output.auth_status === 'ok') cacheAdmin(cwd, output.admin);

  printOutput(output, json);

  return EXIT_CODES.OK;
};
