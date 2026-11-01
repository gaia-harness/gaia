/**
 * `gaia update crossing rekey --baseline-tag <tag> [--extra-tag <tag>]...`:
 * writes a rekeyed copy of each named bundle tree, so the ordinary
 * three-way merge reads the moved app's files at their new paths instead of
 * as deletions, and rewrites the decision log's paths to match.
 *
 * It takes tags, never paths: the source is always a verified tree in the
 * update cache and the destination always sits beside it. A destination is
 * reused only when its digest, written last, matches the source manifest, so a
 * half-written copy can never be taken for a finished one. The rekeyed
 * manifest is written only here.
 */
import {createHash, randomBytes} from 'node:crypto';
import {
  copyFileSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {
  compareCodeUnits,
  DECISIONS_FILE,
  done,
  MANIFEST_FILE,
  mapLeadingRoot,
  NEW_PACKAGE_ROOT,
  NEW_PREFIX,
  readTextIfPresent,
  stop,
  topLevelOf,
  UPDATE_CACHE,
} from './crossing-shared.js';
import type {Outcome} from './crossing-shared.js';

export type RekeyArguments =
  (RekeyOptions & {ok: true}) | {message: string; ok: false};

export type RekeyOptions = {baselineTag: string; extraTags: string[]};

type Source = {digest: string; files: string[]; manifest: string; tag: string};

const TAG_PATTERN = /^[A-Za-z0-9][\w.+-]*$/u;
const DIGEST_FILE = '.source-digest';
// eslint-disable-next-line no-control-regex -- refusing control characters is the point
const CONTROL_CHARACTER = /[\u0000-\u001F\u007F]/u;

const isTag = (value: string): boolean =>
  TAG_PATTERN.test(value) && !value.includes('..');

export const parseRekeyArguments = (
  argv: readonly string[]
): RekeyArguments => {
  let baselineTag: string | undefined;
  const extraTags: string[] = [];

  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];

    if (flag !== '--baseline-tag' && flag !== '--extra-tag') {
      return {message: `unknown flag: ${String(flag)}`, ok: false};
    }

    if (value === undefined || !isTag(value)) {
      return {message: `${flag} needs a release tag`, ok: false};
    }

    if (flag === '--baseline-tag') {
      baselineTag = value;
    } else {
      extraTags.push(value);
    }
  }

  return baselineTag === undefined ?
      {message: '--baseline-tag is required', ok: false}
    : {baselineTag, extraTags, ok: true};
};

const occupiesNewHome = (value: string): boolean =>
  value === NEW_PACKAGE_ROOT || value.startsWith(NEW_PREFIX);

const isPlainKey = (key: string): boolean =>
  key !== '' &&
  !key.startsWith('/') &&
  !key.includes('\\') &&
  !CONTROL_CHARACTER.test(key) &&
  key
    .split('/')
    .every((segment) => segment !== '' && segment !== '.' && segment !== '..');

/** Every file under `directory` as a relative path, or undefined at a symlink. */
const listFiles = (directory: string, prefix = ''): string[] | undefined => {
  const found: string[] = [];

  for (const entry of readdirSync(path.join(directory, prefix), {
    withFileTypes: true,
  })) {
    const relative = prefix === '' ? entry.name : `${prefix}/${entry.name}`;

    if (entry.isSymbolicLink()) return undefined;

    if (entry.isDirectory()) {
      const nested = listFiles(directory, relative);

      if (nested === undefined) return undefined;
      found.push(...nested);
    } else {
      found.push(relative);
    }
  }

  return found;
};

const cacheDirectory = (root: string, tag: string): string =>
  path.join(root, UPDATE_CACHE, tag);

const inspect = (root: string, tag: string): Outcome | Source => {
  const tree = path.join(cacheDirectory(root, tag), 'tree');
  let stats;

  try {
    stats = lstatSync(tree);
  } catch {
    stats = undefined;
  }

  if (!stats?.isDirectory()) {
    return stop(
      'tree-missing',
      `re-run the update's download step so the ${tag} bundle tree is in the update cache, then re-run the note`
    );
  }

  const files = listFiles(tree);

  if (files === undefined) {
    return stop(
      'symlink',
      `delete the ${tag} directory from the update cache so it is downloaded again, then re-run the note`
    );
  }

  const manifest = readTextIfPresent(path.join(tree, MANIFEST_FILE));
  let keys: string[] | undefined;

  try {
    const parsed = JSON.parse(manifest ?? '') as {
      files?: Record<string, unknown>;
    };

    keys = Object.keys(parsed.files ?? {});
  } catch {
    keys = undefined;
  }

  if (manifest === undefined || keys === undefined) {
    return stop(
      'manifest-unreadable',
      `delete the ${tag} directory from the update cache so it is downloaded again, then re-run the note`
    );
  }

  if (!keys.every(isPlainKey)) {
    return stop(
      'manifest-key',
      `report the ${tag} bundle manifest, which holds a key that is not a plain relative path, and do not continue`
    );
  }

  if (keys.some(occupiesNewHome) || files.some(occupiesNewHome)) {
    return stop(
      'new-home-occupied',
      `report the ${tag} bundle, which already holds paths at the app's new home, and do not continue`
    );
  }

  return {
    digest: createHash('sha256').update(manifest).digest('hex'),
    files,
    manifest,
    tag,
  };
};

const rekeyedManifest = (manifest: string): string => {
  const parsed = JSON.parse(manifest) as {files: Record<string, unknown>};
  const mapped = Object.entries(parsed.files)
    .map(([key, value]): [string, unknown] => [mapLeadingRoot(key), value])
    .toSorted(([left], [right]) => compareCodeUnits(left, right));

  return `${JSON.stringify({...parsed, files: Object.fromEntries(mapped)}, null, 2)}\n`;
};

const build = (root: string, source: Source): string => {
  const directory = cacheDirectory(root, source.tag);
  const destination = path.join(directory, 'tree-rekeyed');
  const reusable =
    readTextIfPresent(path.join(destination, DIGEST_FILE)) === source.digest;

  for (const name of readdirSync(directory)) {
    if (name.startsWith('tree-rekeyed.tmp.')) {
      rmSync(path.join(directory, name), {force: true, recursive: true});
    }
  }
  if (reusable) return destination;

  rmSync(destination, {force: true, recursive: true});
  const scratch = `${destination}.tmp.${randomBytes(6).toString('hex')}`;
  const tree = path.join(directory, 'tree');

  for (const relative of source.files.filter(
    (file) => file !== MANIFEST_FILE
  )) {
    const target = path.join(scratch, mapLeadingRoot(relative));

    mkdirSync(path.dirname(target), {recursive: true});
    copyFileSync(path.join(tree, relative), target);
  }
  mkdirSync(path.join(scratch, '.gaia'), {recursive: true});
  writeFileSync(
    path.join(scratch, MANIFEST_FILE),
    rekeyedManifest(source.manifest)
  );
  writeFileSync(path.join(scratch, DIGEST_FILE), source.digest);
  renameSync(scratch, destination);

  return destination;
};

type Decision = Record<string, unknown> & {key?: unknown; path?: unknown};

const readDecisions = (
  root: string
):
  | null
  | undefined
  | {decisions: Decision[]; document: Record<string, unknown>} => {
  const text = readTextIfPresent(path.join(root, DECISIONS_FILE));

  if (text === undefined) return null;

  try {
    const document = JSON.parse(text) as Record<string, unknown>;

    return Array.isArray(document.decisions) ?
        {decisions: document.decisions as Decision[], document}
      : undefined;
  } catch {
    return undefined;
  }
};

const keyOf = (entry: Decision): string =>
  typeof entry.key === 'string' ? entry.key : '';

const rekeyDecisions = (root: string): string[] => {
  const log = readDecisions(root);
  const lines: string[] = [];

  if (log === null || log === undefined) return lines;

  for (const entry of log.decisions) {
    if (typeof entry.path === 'string') {
      const mapped = mapLeadingRoot(entry.path);

      if (mapped !== entry.path) {
        lines.push(`REKEYED_DECISION\t${entry.path}\t${mapped}`);
        entry.path = mapped;
      }
    }
  }
  if (lines.length === 0) return lines;

  log.decisions.sort(
    (left, right) =>
      compareCodeUnits(String(left.path), String(right.path)) ||
      compareCodeUnits(keyOf(left), keyOf(right))
  );
  atomicWriteFileSync(
    path.join(root, DECISIONS_FILE),
    `${JSON.stringify(log.document, null, 2)}\n`
  );

  return lines;
};

export const runRekey = (
  workingDirectory: string,
  options: RekeyOptions
): Outcome => {
  const root = topLevelOf(workingDirectory);

  if (root === undefined) {
    return stop(
      'not-root-launch',
      'start the session at the repository root and re-run the note'
    );
  }

  if (readDecisions(root) === undefined) {
    return stop(
      'decisions-unreadable',
      'fix .gaia/update-decisions.json so it is valid JSON with a decisions array, then re-run the note'
    );
  }

  const tags = [...new Set([options.baselineTag, ...options.extraTags])];
  const sources: Source[] = [];

  for (const tag of tags) {
    const inspected = inspect(root, tag);

    if ('exit' in inspected) return inspected;
    sources.push(inspected);
  }

  const directories = new Map(
    sources.map((source) => [source.tag, build(root, source)])
  );
  const relativeOf = (tag: string): string =>
    path
      .relative(root, directories.get(tag) ?? '')
      .split(path.sep)
      .join('/');
  const lines = [
    `BASELINE_DIR=${relativeOf(options.baselineTag)}`,
    ...options.extraTags.map((tag) => `EXTRA_DIR=${tag}:${relativeOf(tag)}`),
    ...rekeyDecisions(root),
  ];

  return done(lines);
};
