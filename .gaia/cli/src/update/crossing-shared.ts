/**
 * Constants and helpers the crossing verbs share. The old package root is
 * spelled here once, as a bare name, and every prefix is composed from it, so
 * a mechanical path rewrite of the shipped source never changes what the
 * crossing recognizes as the old layout.
 */
import {existsSync, lstatSync, readFileSync, realpathSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {execGaiaGit} from '../util/git-env.js';

export type Outcome = {exit: number; lines: string[]};

export const LEGACY_PACKAGE_ROOT = 'frontend';

export const LEGACY_PACKAGE_NAME = LEGACY_PACKAGE_ROOT;

export const NEW_PACKAGE_NAME = 'web';

export const APPS_DIRECTORY = 'apps';

export const PACKAGES_DIRECTORY = 'packages';

export const NEW_PACKAGE_ROOT = `${APPS_DIRECTORY}/${NEW_PACKAGE_NAME}`;

export const LEGACY_PREFIX = `${LEGACY_PACKAGE_ROOT}/`;

export const NEW_PREFIX = `${NEW_PACKAGE_ROOT}/`;

export const REGISTRY_FILE = '.gaia/packages.json';

export const MANIFEST_FILE = '.gaia/manifest.json';

export const DECISIONS_FILE = '.gaia/update-decisions.json';

export const AUDIT_ROSTER_FILE = '.gaia/audit-ci.yml';

export const UPDATE_CACHE = '.gaia/local/cache/shared/update-gaia';

export const DESCRIPTOR_FILE = 'gaia.package.json';

export type RegistryEntry = {name: string; path: string};

export const done = (lines: string[] = []): Outcome => ({
  exit: EXIT_CODES.OK,
  lines,
});

/** One refusal: the reason line, then the imperative next step, exit 3. */
export const stop = (reason: string, nextStep: string): Outcome => ({
  exit: EXIT_CODES.COULD_NOT_RUN,
  lines: [`CROSSING_STOP ${reason}`, `Next step: ${nextStep}`],
});

export const reportLine = (kind: string, detail: string): string =>
  `REPORT\t${kind}\t${detail}`;

/** The real path of the repository top level that holds `directory`, or undefined. */
export const topLevelOf = (directory: string): string | undefined => {
  try {
    return realpathSync(
      execGaiaGit(['rev-parse', '--show-toplevel'], directory)
    );
  } catch {
    return undefined;
  }
};

export const isDirectory = (target: string): boolean => {
  try {
    return lstatSync(target).isDirectory();
  } catch {
    return false;
  }
};

export const isSymlink = (target: string): boolean => {
  try {
    return lstatSync(target).isSymbolicLink();
  } catch {
    return false;
  }
};

export const readTextIfPresent = (file: string): string | undefined =>
  existsSync(file) ? readFileSync(file, 'utf8') : undefined;

/**
 * The registry entries, with an absent file reading as the single legacy
 * entry. Undefined when the file is present but not an array of entries.
 */
export const readRegistry = (root: string): RegistryEntry[] | undefined => {
  const text = readTextIfPresent(path.join(root, REGISTRY_FILE));

  if (text === undefined) {
    return [{name: LEGACY_PACKAGE_NAME, path: LEGACY_PACKAGE_ROOT}];
  }

  try {
    const parsed: unknown = JSON.parse(text);

    if (!Array.isArray(parsed)) return undefined;
    const entries: RegistryEntry[] = [];

    for (const item of parsed as unknown[]) {
      if (typeof item !== 'object' || item === null) return undefined;
      const {name, path: entryPath} = item as Record<string, unknown>;

      if (typeof name !== 'string' || typeof entryPath !== 'string') {
        return undefined;
      }
      entries.push({name, path: entryPath});
    }

    return entries;
  } catch {
    return undefined;
  }
};

/** The keys of the manifest's `files` map, or undefined when unreadable. */
export const manifestKeys = (text: string): string[] | undefined => {
  try {
    const parsed = JSON.parse(text) as {files?: unknown};

    if (
      typeof parsed.files !== 'object' ||
      parsed.files === null ||
      Array.isArray(parsed.files)
    ) {
      return undefined;
    }

    return Object.keys(parsed.files);
  } catch {
    return undefined;
  }
};

/** The leading old root mapped to the new one; any other path unchanged. */
export const mapLeadingRoot = (value: string): string =>
  value.startsWith(LEGACY_PREFIX) ?
    NEW_PREFIX + value.slice(LEGACY_PREFIX.length)
  : value;

/** Code-unit string order, the order `jq` sorts by. */
export const compareCodeUnits = (left: string, right: string): number => {
  if (left < right) return -1;

  return left > right ? 1 : 0;
};

export type ListItem = {
  head: string;
  quote: string;
  rest: string;
  value: string;
};

/** One YAML block-list line split around its value, or undefined for any other line. */
export const parseListItem = (line: string): ListItem | undefined => {
  const trimmed = line.trimStart();

  if (!trimmed.startsWith('-')) return undefined;
  const afterDash = trimmed.slice(1);
  const body = afterDash.trimStart();

  if (body === afterDash || body === '') return undefined;
  const head = line.slice(0, line.length - body.length);
  const quote =
    body.startsWith('"') || body.startsWith("'") ? body.charAt(0) : '';

  if (quote !== '') {
    const close = body.indexOf(quote, 1);

    return close === -1 ? undefined : (
        {head, quote, rest: body.slice(close + 1), value: body.slice(1, close)}
      );
  }
  const comment = body.indexOf(' #');
  const value = (comment === -1 ? body : body.slice(0, comment)).trimEnd();

  return {head, quote, rest: body.slice(value.length), value};
};

export const isBlankOrComment = (line: string): boolean => {
  const trimmed = line.trim();

  return trimmed === '' || trimmed.startsWith('#');
};
