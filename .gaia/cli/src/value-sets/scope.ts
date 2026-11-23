import picomatch from 'picomatch';
import {closeSync, lstatSync, openSync, readFileSync, readSync} from 'node:fs';
import path from 'node:path';
import {execGaiaGitRaw} from '../util/git-env.js';
import {gitZArgs, splitZStream} from '../util/git-z.js';
import type {CannotRun} from './policy.js';
import type {SetLanguage} from './types.js';

export type ScopeFile = {language: SetLanguage; path: string; text: string};

const EXCLUDED_DIRECTORIES: ReadonlySet<string> = new Set([
  '.git',
  '.react-router',
  '__snapshots__',
  'build',
  'coverage',
  'dist',
  'fixtures',
  'node_modules',
  'storybook-static',
  'test-fixtures',
]);

const TYPESCRIPT_EXTENSIONS: ReadonlySet<string> = new Set([
  '.cts',
  '.mts',
  '.ts',
  '.tsx',
]);

const SHELL_EXTENSIONS: ReadonlySet<string> = new Set([
  '.bash',
  '.bats',
  '.sh',
]);

const SHELL_INTERPRETERS: ReadonlySet<string> = new Set(['bash', 'bats', 'sh']);

const FIRST_LINE_CHUNK_BYTES = 256;
const FIRST_LINE_LIMIT_BYTES = 4096;
const NEWLINE_BYTE = 0x0a;

/** Reads only as many bytes as the first line needs. */
const readFirstLine = (file: string): string => {
  const descriptor = openSync(file, 'r');

  try {
    const chunks: Buffer[] = [];
    let total = 0;

    while (total < FIRST_LINE_LIMIT_BYTES) {
      const chunk = Buffer.alloc(FIRST_LINE_CHUNK_BYTES);
      const read = readSync(
        descriptor,
        chunk,
        0,
        FIRST_LINE_CHUNK_BYTES,
        total
      );

      if (read === 0) break;

      const filled = chunk.subarray(0, read);

      chunks.push(filled);
      total += read;

      if (filled.includes(NEWLINE_BYTE)) break;
    }

    return Buffer.concat(chunks).toString('latin1').split('\n', 1)[0] ?? '';
  } finally {
    closeSync(descriptor);
  }
};

/** True when a first line is a shebang naming a shell directly or through `env`. */
const isShellShebang = (line: string): boolean => {
  if (!line.startsWith('#!')) return false;

  const tokens = line.slice(2).split(/\s+/).filter(Boolean);
  const [program = '', ...rest] = tokens;
  const named =
    path.basename(program) === 'env' ?
      rest.find((token) => !token.startsWith('-'))
    : program;

  return named !== undefined && SHELL_INTERPRETERS.has(path.basename(named));
};

const languageOf = (
  relative: string,
  absolute: string
): SetLanguage | undefined => {
  const extension = path.extname(relative);

  if (TYPESCRIPT_EXTENSIONS.has(extension)) return 'typescript';

  if (SHELL_EXTENSIONS.has(extension)) return 'shell';

  if (extension !== '') return undefined;

  return isShellShebang(readFirstLine(absolute)) ? 'shell' : undefined;
};

const isRegularFile = (absolute: string): boolean => {
  try {
    return lstatSync(absolute).isFile();
  } catch {
    return false;
  }
};

const byPath = (a: string, b: string): number => {
  if (a < b) return -1;

  return a > b ? 1 : 0;
};

const readEntry = (
  root: string,
  relative: string
): CannotRun | ScopeFile | undefined => {
  const absolute = path.join(root, relative);

  if (!isRegularFile(absolute)) return undefined;

  let language: SetLanguage | undefined;
  let bytes: Buffer;

  try {
    language = languageOf(relative, absolute);
    bytes = language === undefined ? Buffer.alloc(0) : readFileSync(absolute);
  } catch {
    return {ok: false, reason: `cannot read ${relative}`};
  }

  if (language === undefined) return undefined;

  try {
    return {
      language,
      path: relative,
      text: new TextDecoder('utf-8', {fatal: true}).decode(bytes),
    };
  } catch {
    return {ok: false, reason: `${relative} is not valid UTF-8`};
  }
};

/**
 * Every tracked, staged or untracked-but-not-ignored regular TypeScript or
 * shell file under `root`, read from the working tree, sorted by path.
 */
export const collectScope = (options: {
  exclude: readonly string[];
  root: string;
}): CannotRun | {files: readonly ScopeFile[]; ok: true} => {
  const {exclude, root} = options;
  let listed: string;

  try {
    listed = execGaiaGitRaw(
      gitZArgs('ls-files', ['--cached', '--others', '--exclude-standard']),
      root
    );
  } catch {
    return {ok: false, reason: 'cannot list files'};
  }

  const isExcludedByConfig =
    exclude.length > 0 ? picomatch([...exclude], {dot: true}) : () => false;
  const paths = [...new Set(splitZStream(listed))]
    .filter(
      (relative) =>
        !relative
          .split('/')
          .slice(0, -1)
          .some((segment) => EXCLUDED_DIRECTORIES.has(segment))
    )
    .filter((relative) => !isExcludedByConfig(relative))
    .toSorted(byPath);
  const files: ScopeFile[] = [];

  for (const relative of paths) {
    const entry = readEntry(root, relative);

    if (entry !== undefined && 'ok' in entry) return entry;

    if (entry !== undefined) files.push(entry);
  }

  return {files, ok: true};
};
