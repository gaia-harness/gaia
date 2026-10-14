import {spawnSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import path from 'node:path';
import type {FileKind, Ownership} from './types.js';

/** Names the script to run in place of the project's own classifier. */
export const OWNERSHIP_CLASSIFIER_ENV = 'GAIA_FITNESS_OWNERSHIP_CLASSIFIER';

const DEFAULT_CLASSIFIER = '.gaia/scripts/fitness-ownership.sh';

/**
 * A classifier that hangs would hang the whole check; ownership only gates
 * heal, so a slow classifier degrades to `unknown` instead.
 */
const CLASSIFIER_TIMEOUT_MS = 30_000;

/** One line per input path, so 16 MiB is far past any real answer. */
const CLASSIFIER_MAX_BUFFER_BYTES = 16 * 1024 * 1024;

const CLASSES: ReadonlySet<string> = new Set([
  'adopter',
  'gaia-shipped',
  'ignored',
  'third-party',
]);

// eslint-disable-next-line no-control-regex
const CONTROL_CHARACTER = /[\u0000-\u001F\u007F]/;

/** Only these variables reach the classifier; nothing the project controls does. */
const SCRUBBED_ENV_KEYS = ['PATH', 'HOME', 'LANG', 'LC_ALL'] as const;

const scrubbedEnvironment = (): Record<string, string> => {
  const scrubbed: Record<string, string> = {};

  for (const key of SCRUBBED_ENV_KEYS) {
    const value = process.env[key];

    if (value !== undefined) scrubbed[key] = value;
  }

  return scrubbed;
};

const parseClasses = (
  stdout: string,
  expectedCount: number
): Ownership[] | undefined => {
  const lines = stdout.split('\n');

  if (lines.at(-1) === '') lines.pop();

  if (lines.length !== expectedCount) return undefined;

  const classes: Ownership[] = [];

  for (const line of lines) {
    const separator = line.indexOf('\t');
    const className = separator === -1 ? line : line.slice(0, separator);

    if (!CLASSES.has(className)) return undefined;
    classes.push(className as Ownership);
  }

  return classes;
};

/**
 * Classifies each repo-relative path with one classifier spawn.
 *
 * Fails toward `unknown`, never toward `adopter`: a missing classifier, a
 * non-zero exit, a timeout or an answer whose line count differs from the
 * input count makes every path `unknown`. A path holding a control character
 * is `unknown` and is never passed, since it could split a record.
 */
export const classifyOwnership = (input: {
  env?: Readonly<Record<string, string | undefined>>;
  paths: readonly string[];
  root: string;
}): Map<string, Ownership> => {
  const result = new Map<string, Ownership>();
  const passable: string[] = [];

  for (const candidate of input.paths) {
    result.set(candidate, 'unknown');
    if (!CONTROL_CHARACTER.test(candidate)) passable.push(candidate);
  }

  if (passable.length === 0) return result;

  const seam = (input.env ?? process.env)[OWNERSHIP_CLASSIFIER_ENV];
  const classifier =
    seam === undefined || seam === '' ?
      path.join(input.root, DEFAULT_CLASSIFIER)
    : seam;

  if (!existsSync(classifier)) return result;

  const spawned = spawnSync(
    'bash',
    [classifier, '--root', input.root, '--', ...passable],
    {
      encoding: 'utf8',
      env: scrubbedEnvironment(),
      maxBuffer: CLASSIFIER_MAX_BUFFER_BYTES,
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: CLASSIFIER_TIMEOUT_MS,
    }
  );

  if (spawned.error !== undefined || spawned.status !== 0) return result;

  const classes = parseClasses(spawned.stdout, passable.length);

  if (classes === undefined) return result;

  for (const [index, candidate] of passable.entries()) {
    result.set(candidate, classes[index] ?? 'unknown');
  }

  return result;
};

/**
 * A per-machine local file is gitignored by design, which the classifier reads
 * as `ignored`; it is the project's own and Claude Code loads it, so it counts
 * as `adopter`. Every other combination keeps the classified ownership.
 */
export const effectiveOwnership = (
  classified: Ownership,
  kinds: readonly FileKind[]
): Ownership => {
  const isLocal =
    kinds.includes('settings-local') || kinds.includes('claudemd-local');

  return isLocal && classified === 'ignored' ? 'adopter' : classified;
};
