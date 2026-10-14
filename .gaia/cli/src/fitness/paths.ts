import type {RuleContext} from './context.js';
import {bodyLines, stripInlineCode} from './markdown.js';
import type {ProjectFile, RawFinding} from './types.js';

export type ImportReference = {
  line: number;
  token: string;
};

export type PathReference = {
  line: number;
  /** True when the token came from a markdown link, which also resolves against the file's folder. */
  linked: boolean;
  token: string;
};

/**
 * Extensions a slash-free backticked token must carry to count as a file. A
 * bare `console.log` or `v1.2` is code or prose, and flagging it as a dead
 * file would drown the real findings.
 */
const BARE_FILE_EXTENSIONS = new Set([
  'bats',
  'cjs',
  'css',
  'html',
  'js',
  'json',
  'jsonc',
  'jsonl',
  'md',
  'mdx',
  'mjs',
  'sh',
  'toml',
  'ts',
  'tsx',
  'txt',
  'yaml',
  'yml',
]);

const PATH_CHARACTERS = /^[\w./@+-]+$/;

export const LINE_SUFFIX = /:\d+(?:-\d+)?$/;
const EXTENSION = /\.([A-Za-z0-9]+)$/;

// A host name leading the token (`site.com/docs`) is a web address, and a
// leading `@` is an npm scope: neither names a file in the project. The top
// level domains are listed because `foo.sh/bar` could still be a folder.
const WEB_ADDRESS =
  /^[\da-z-]+(?:\.[\da-z-]+)*\.(?:ai|app|co|com|dev|edu|gov|io|net|org)\//i;
const ELLIPSIS_SEGMENT = /(?:^|\/)\.{3,}(?:\/|$)/;

/** Normalizes a candidate token; undefined when it is not a repo-relative path. */
export const asRepositoryPath = (candidate: string): string | undefined => {
  const token = (candidate.split('#', 1)[0] ?? '').replace(LINE_SUFFIX, '');

  if (
    token === '' ||
    token.startsWith('/') ||
    token.startsWith('-') ||
    token.startsWith('@')
  ) {
    return undefined;
  }

  if (!PATH_CHARACTERS.test(token)) return undefined;

  if (WEB_ADDRESS.test(token) || ELLIPSIS_SEGMENT.test(token)) {
    return undefined;
  }

  // `.md` names an extension, not a file; a dotfile such as `.eslintrc.json`
  // carries a second segment.
  if (
    /^\.[A-Za-z0-9]+$/.test(token) &&
    BARE_FILE_EXTENSIONS.has(token.slice(1))
  ) {
    return undefined;
  }

  if (token.includes('/')) return token;

  const extension = EXTENSION.exec(token)?.[1];

  return extension !== undefined && BARE_FILE_EXTENSIONS.has(extension) ?
      token
    : undefined;
};

export const BACKTICKED = /`([^`\n]+)`/g;
const LINK_TARGET = /\]\(([^)\s]+)\)/g;
const SCHEME = /^[A-Za-z][A-Za-z0-9+.-]*:/;

/** Backticked and markdown-linked repo-relative paths in `text`, outside fenced code. */
export const extractPathReferences = (text: string): PathReference[] => {
  const references: PathReference[] = [];

  for (const [index, line] of bodyLines(text).entries()) {
    for (const match of line.matchAll(BACKTICKED)) {
      const token = asRepositoryPath(match[1] ?? '');

      if (token !== undefined) {
        references.push({line: index + 1, linked: false, token});
      }
    }

    for (const match of stripInlineCode(line).matchAll(LINK_TARGET)) {
      const target = match[1] ?? '';
      const token = SCHEME.test(target) ? undefined : asRepositoryPath(target);

      if (token !== undefined) {
        references.push({line: index + 1, linked: true, token});
      }
    }
  }

  return references;
};

const IMPORT = /(?:^|\s)@(\S+)/g;
const TRAILING_PUNCTUATION = new Set([')', ',', '.', ':', ';']);

const trimTrailingPunctuation = (value: string): string => {
  let end = value.length;

  while (end > 0 && TRAILING_PUNCTUATION.has(value.charAt(end - 1))) end -= 1;

  return value.slice(0, end);
};

/**
 * `@path` imports in `text`: an `@` at the start of a line or after
 * whitespace, outside code. A bare `@mention` with no `/` or `.` is not a file.
 */
export const extractImports = (text: string): ImportReference[] => {
  const imports: ImportReference[] = [];

  for (const [index, line] of bodyLines(text).entries()) {
    for (const match of stripInlineCode(line).matchAll(IMPORT)) {
      const token = trimTrailingPunctuation(match[1] ?? '');

      if (token.includes('/') || token.includes('.')) {
        imports.push({line: index + 1, token});
      }
    }
  }

  return imports;
};

export type ReferenceBase = 'file-dir' | 'package' | 'root';

const PACKAGE_FOLDER = /^(.+?)\/\.claude\/|^(.+)\/CLAUDE(?:\.local)?\.md$/;

/**
 * A path in the folder a nested file's package starts at: the folder holding
 * its `.claude`, or a nested CLAUDE.md's own folder. Resolving against it with
 * the `file-dir` base tries the package root without widening the context
 * contract. Undefined for a file at the project root.
 */
const packageAnchor = (fromFile: string): string | undefined => {
  const match = PACKAGE_FOLDER.exec(fromFile);
  const folder = match?.[1] ?? match?.[2];

  return folder === undefined ? undefined : `${folder}/_`;
};

export type ReferenceStatus =
  | {relative: string; status: 'dead'}
  | {relative: string; status: 'found'}
  | {status: 'outside'}
  | {status: 'unresolvable'};

/**
 * Where a path token points. Anything found under any base counts as found;
 * otherwise a target that leaves the root under every base is `outside`, never read and never
 * dead. A gitignored target is a runtime artifact absent from a fresh clone, so
 * it is found rather than dead.
 */
export const resolveReference = (
  context: RuleContext,
  reference: {
    bases: readonly ReferenceBase[];
    fromFile: string;
    token: string;
  }
): ReferenceStatus => {
  const {bases, fromFile, token} = reference;

  // A home-relative token leaves the project by construction; joining it to the
  // root would misread `~` as a folder name.
  if (token.startsWith('~')) return {status: 'outside'};

  const results = bases.flatMap((base) => {
    if (base !== 'package') return [context.resolve(fromFile, token, base)];

    const anchor = packageAnchor(fromFile);

    return anchor === undefined ?
        []
      : [context.resolve(anchor, token, 'file-dir')];
  });
  const found = results.find(
    (result) => result.status === 'inside' && result.exists
  );

  if (found?.status === 'inside') {
    return {relative: found.relative, status: 'found'};
  }

  if (
    results.length > 0 &&
    results.every((result) => result.status === 'outside')
  ) {
    return {status: 'outside'};
  }

  const inside = results.find((result) => result.status === 'inside');

  if (inside?.status !== 'inside') return {status: 'unresolvable'};

  if (context.gitIgnored(inside.relative) === true) {
    return {relative: inside.relative, status: 'found'};
  }

  return {relative: inside.relative, status: 'dead'};
};

const basenameSets = new WeakMap<ReadonlySet<string>, ReadonlySet<string>>();

/** The file names (last segments) of every tracked path, built once per project. */
const trackedBasenames = (context: RuleContext): ReadonlySet<string> => {
  const cached = basenameSets.get(context.allTrackedPaths);

  if (cached !== undefined) return cached;

  const names = new Set(
    [...context.allTrackedPaths].map(
      (tracked) => tracked.split('/').pop() ?? ''
    )
  );

  basenameSets.set(context.allTrackedPaths, names);

  return names;
};

/**
 * One finding per backticked or linked path in `files` that does not exist.
 * A path is also tried from the package a nested file belongs to, and a bare
 * file name is found wherever a tracked file carries it: prose names the file,
 * not where it lives.
 */
export const deadPathFindings = (
  context: RuleContext,
  files: readonly ProjectFile[]
): RawFinding[] =>
  files.flatMap((file) =>
    extractPathReferences(file.text).flatMap(({line, linked, token}) => {
      if (!token.includes('/') && trackedBasenames(context).has(token)) {
        return [];
      }

      const status = resolveReference(context, {
        bases: linked ? ['root', 'file-dir', 'package'] : ['root', 'package'],
        fromFile: file.path,
        token,
      });

      return status.status === 'dead' ?
          [
            {
              file: file.path,
              line,
              message: `The path ${token} does not exist.`,
              remediation:
                'Update the path to where the file lives now, or remove the reference.',
            },
          ]
        : [];
    })
  );
