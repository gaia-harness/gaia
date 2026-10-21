/**
 * `gaia init wire-statusline` handler.
 *
 * Replaces the model-authored JSON-merge in Step 3 of `/gaia-init` with
 * a deterministic CLI write to the project's `<cwd>/.claude/settings.json`.
 *
 * The merge inserts the canonical GAIA `statusLine` block at the top
 * level, preserving every existing key. If a `statusLine` is already
 * present and points at a non-GAIA command, it is overwritten; the
 * runbook's intent is "this project's statusline is GAIA's wrapper."
 *
 * Atomic writes: temp + rename. Stdout: nothing on success. Exit codes:
 * 0 / 1 / 2.
 */
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = `Usage: gaia init wire-statusline

  Wire the GAIA statusline into the project's .claude/settings.json.

  Exit codes:
    0  success (no stdout)
    1  user-correctable error (unknown flag, invalid JSON in target)
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'wire-statusline';

/**
 * Canonical GAIA statusline block. The command is rooted at the repository
 * it belongs to rather than written relative to the working directory,
 * matching how `.claude/settings.json` spells every hook registration and
 * how `.gaia/scripts/check-hook-command-rooting.sh` requires them to be
 * spelled.
 *
 * A project-relative `bash .gaia/statusline/...` is wrong, not merely
 * untidy: the working directory persists across a session, so a single `cd`
 * leaves it unresolvable. `$CLAUDE_PROJECT_DIR` alone is not
 * the root either: it does not follow entry into a linked worktree, so it
 * serves only as the fallback for a working directory outside any
 * repository.
 *
 * `refreshInterval` re-runs the command on a timer because Claude Code does
 * not re-run it when the terminal is resized, so a width-fitted line would
 * otherwise stay stale until the next message.
 */
/* eslint-disable no-template-curly-in-string -- literal shell `${ }` syntax, not JS interpolation */
const STATUSLINE_BLOCK = {
  command:
    'bash "$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-.}")/.gaia/statusline/gaia-statusline.sh"',
  refreshInterval: 15,
  type: 'command',
} as const;
/* eslint-enable no-template-curly-in-string */

/**
 * Insert a single key into an object at the alphabetically-correct
 * position relative to existing keys. Preserves insertion order
 * everywhere else.
 */
const insertAlphabetical = (
  source: Record<string, unknown>,
  key: string,
  value: unknown
): Record<string, unknown> => {
  const next: Record<string, unknown> = {};
  let inserted = false;

  for (const existing of Object.keys(source)) {
    if (!inserted && existing > key) {
      next[key] = value;
      inserted = true;
    }

    // Skip the old value at `key`; the new entry overwrites at the
    // alphabetical slot instead.
    if (existing !== key) next[existing] = source[existing];
  }

  if (!inserted) next[key] = value;

  return next;
};

const readSettings = (target: string): Record<string, unknown> => {
  if (!existsSync(target)) return {};
  const raw = readFileSync(target, 'utf8').trim();

  if (raw.length === 0) return {};
  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(`${target} is not valid JSON`);
  }

  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`${target} must be a JSON object`);
  }

  return parsed as Record<string, unknown>;
};

const writeSettings = (
  target: string,
  value: Record<string, unknown>
): void => {
  mkdirSync(path.dirname(target), {recursive: true});
  const serialized = `${JSON.stringify(value, null, 2)}\n`;
  const tmp = `${target}.tmp`;
  writeFileSync(tmp, serialized, 'utf8');
  renameSync(tmp, target);
};

const STATUSLINE_KEY = 'statusLine';

/**
 * Decides whether the existing block already matches the canonical GAIA
 * one. Used for idempotency.
 */
const matchesCanonical = (existing: unknown): boolean => {
  if (
    existing === null ||
    typeof existing !== 'object' ||
    Array.isArray(existing)
  ) {
    return false;
  }
  const candidate = existing as Record<string, unknown>;

  return (
    candidate.type === STATUSLINE_BLOCK.type &&
    candidate.command === STATUSLINE_BLOCK.command &&
    // Any interval counts, so an adopter's tuned value survives a re-run;
    // only a block without one is rewritten to gain it.
    typeof candidate.refreshInterval === 'number'
  );
};

export const mergeStatusline = (
  source: Record<string, unknown>
): Record<string, unknown> => {
  if (matchesCanonical(source[STATUSLINE_KEY])) return source;

  return insertAlphabetical(source, STATUSLINE_KEY, {...STATUSLINE_BLOCK});
};

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
      subcommand: 'init wire-statusline',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const target = path.join(cwd, '.claude', 'settings.json');

  try {
    const current = readSettings(target);
    const merged = mergeStatusline(current);
    writeSettings(target, merged);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);

    if (message.includes('not valid JSON') || message.includes('JSON object')) {
      structuredError({
        code: 'settings_malformed',
        message,
        subcommand: 'init wire-statusline',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
    structuredError({
      code: 'wire_statusline_failed',
      message,
      subcommand: 'init wire-statusline',
    });

    return UNEXPECTED_EXIT;
  }

  try {
    markStepCompleted(cwd, STEP_NAME);
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init wire-statusline',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
