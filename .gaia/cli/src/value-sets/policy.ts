import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {MAINTAINER_MARKER_PATH} from '../fitness/rules/line-limit.js';

const VALUE_SETS_CONFIG_PATH = '.gaia/value-sets.json';

const MANIFEST_PATH = '.gaia/manifest.json';

const NON_HARNESS_PREFIXES = ['apps/', 'packages/'];

export type CannotRun = {ok: false; reason: string};

export type Policy = {
  exclude: readonly string[];
  harnessPaths: ReadonlySet<string>;
};

type ConfigResult = CannotRun | {exclude: readonly string[]; ok: true};

type PolicyOptions = {
  configPath?: string;
  cwd: string;
  policyFrom?: string;
  root: string;
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

const isFilled = (value: unknown): value is string =>
  typeof value === 'string' && value.trim() !== '';

const readText = (file: string): string | undefined => {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return undefined;
  }
};

/** Validates a config's text; `shown` is the path the reasons name. */
const interpretConfig = (text: string, shown: string): ConfigResult => {
  let parsed: unknown;

  try {
    parsed = JSON.parse(text);
  } catch {
    return {ok: false, reason: `${shown}: not valid JSON`};
  }

  if (!isRecord(parsed)) {
    return {ok: false, reason: `${shown}: must hold a JSON object`};
  }

  if (parsed.version !== 1) {
    return {ok: false, reason: `${shown}: version must be 1`};
  }

  const unknownKey = Object.keys(parsed).find(
    (key) => key !== 'version' && key !== 'exclude'
  );

  if (unknownKey !== undefined) {
    return {ok: false, reason: `${shown}: unknown key ${unknownKey}`};
  }

  const {exclude} = parsed;

  if (exclude === undefined) return {exclude: [], ok: true};

  if (!Array.isArray(exclude)) {
    return {ok: false, reason: `${shown}: exclude must be a list`};
  }

  const globs: string[] = [];

  for (const [index, entry] of exclude.entries()) {
    const entryRecord = isRecord(entry) ? entry : {};

    if (!isFilled(entryRecord.path)) {
      return {
        ok: false,
        reason: `${shown}: exclude entry ${index} has no path`,
      };
    }

    if (!isFilled(entryRecord.reason)) {
      return {
        ok: false,
        reason: `${shown}: exclude entry ${index} has no reason`,
      };
    }

    globs.push(entryRecord.path);
  }

  return {exclude: globs, ok: true};
};

const configSource = (
  options: PolicyOptions
): {file: string; named: boolean; shown: string} => {
  const {configPath, cwd, policyFrom, root} = options;

  if (policyFrom !== undefined) {
    return {
      file: path.resolve(cwd, policyFrom, VALUE_SETS_CONFIG_PATH),
      named: false,
      shown: path.join(policyFrom, VALUE_SETS_CONFIG_PATH),
    };
  }

  if (configPath !== undefined) {
    return {
      file: path.resolve(cwd, configPath),
      named: true,
      shown: configPath,
    };
  }

  return {
    file: path.join(root, VALUE_SETS_CONFIG_PATH),
    named: false,
    shown: VALUE_SETS_CONFIG_PATH,
  };
};

const loadExclude = (options: PolicyOptions): ConfigResult => {
  const source = configSource(options);
  const text = readText(source.file);
  let exclude: readonly string[] = [];

  if (text === undefined) {
    if (source.named || existsSync(source.file)) {
      return {ok: false, reason: `cannot read ${source.shown}`};
    }
  } else {
    const result = interpretConfig(text, source.shown);

    if (!result.ok) return result;

    exclude = result.exclude;
  }

  if (options.policyFrom === undefined) return {exclude, ok: true};

  // The head's own config is shape-checked, never applied.
  const headText = readText(path.join(options.root, VALUE_SETS_CONFIG_PATH));

  if (headText !== undefined) {
    const head = interpretConfig(headText, VALUE_SETS_CONFIG_PATH);

    if (!head.ok) return head;
  }

  return {exclude, ok: true};
};

const loadHarnessPaths = (
  policyDirectory: string
): CannotRun | {harnessPaths: ReadonlySet<string>; ok: true} => {
  const cannotParse: CannotRun = {
    ok: false,
    reason: `cannot parse ${MANIFEST_PATH}`,
  };
  const manifestText = readText(path.join(policyDirectory, MANIFEST_PATH));
  let files: Record<string, unknown> = {};

  if (manifestText !== undefined) {
    let manifest: unknown;

    try {
      manifest = JSON.parse(manifestText);
    } catch {
      return cannotParse;
    }

    if (!isRecord(manifest) || !isRecord(manifest.files)) return cannotParse;

    ({files} = manifest);
  }

  if (existsSync(path.join(policyDirectory, MAINTAINER_MARKER_PATH))) {
    return {harnessPaths: new Set(), ok: true};
  }

  return {
    harnessPaths: new Set(
      Object.keys(files).filter(
        (file) =>
          !NON_HARNESS_PREFIXES.some((prefix) => file.startsWith(prefix))
      )
    ),
    ok: true,
  };
};

/**
 * Loads the three policy inputs. Without `policyFrom` they come from `root`
 * (`configPath` replacing only the config's source); with it they come only
 * from that directory, where CI places the base branch's copies.
 */
export const loadPolicy = (
  options: PolicyOptions
): CannotRun | {ok: true; policy: Policy} => {
  const exclude = loadExclude(options);

  if (!exclude.ok) return exclude;

  const policyDirectory =
    options.policyFrom === undefined ?
      options.root
    : path.resolve(options.cwd, options.policyFrom);
  const harness = loadHarnessPaths(policyDirectory);

  if (!harness.ok) return harness;

  return {
    ok: true,
    policy: {exclude: exclude.exclude, harnessPaths: harness.harnessPaths},
  };
};
