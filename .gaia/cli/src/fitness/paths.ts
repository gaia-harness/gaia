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

/** Normalizes a candidate token; undefined when it is not a repo-relative path. */
export const asRepositoryPath = (candidate: string): string | undefined => {
  const token = (candidate.split('#', 1)[0] ?? '').replace(LINE_SUFFIX, '');

  if (token === '' || token.startsWith('/') || token.startsWith('-')) {
    return undefined;
  }

  if (!PATH_CHARACTERS.test(token)) return undefined;

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
    bases: readonly ('file-dir' | 'root')[];
    fromFile: string;
    token: string;
  }
): ReferenceStatus => {
  const {bases, fromFile, token} = reference;

  // A home-relative token leaves the project by construction; joining it to the
  // root would misread `~` as a folder name.
  if (token.startsWith('~')) return {status: 'outside'};

  const results = bases.map((base) => context.resolve(fromFile, token, base));
  const found = results.find(
    (result) => result.status === 'inside' && result.exists
  );

  if (found?.status === 'inside') {
    return {relative: found.relative, status: 'found'};
  }

  if (results.every((result) => result.status === 'outside')) {
    return {status: 'outside'};
  }

  const inside = results.find((result) => result.status === 'inside');

  if (inside?.status !== 'inside') return {status: 'unresolvable'};

  if (context.gitIgnored(inside.relative) === true) {
    return {relative: inside.relative, status: 'found'};
  }

  return {relative: inside.relative, status: 'dead'};
};

/** One finding per backticked or linked path in `files` that does not exist. */
export const deadPathFindings = (
  context: RuleContext,
  files: readonly ProjectFile[]
): RawFinding[] =>
  files.flatMap((file) =>
    extractPathReferences(file.text).flatMap(({line, linked, token}) => {
      const status = resolveReference(context, {
        bases: linked ? ['root', 'file-dir'] : ['root'],
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
