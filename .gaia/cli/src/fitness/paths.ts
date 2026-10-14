import {STATE_FILE_RELATIVE} from '../init/util/state.js';
import {escapeRegExp} from '../util/escape-regexp.js';
import type {ResolvedPath, RuleContext} from './context.js';
import {bodyLines, splitFrontmatter, stripInlineCode} from './markdown.js';
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
const EXTENSION = /\.([A-Z0-9]+)$/i;

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
    /^\.[A-Z0-9]+$/i.test(token) &&
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
const SCHEME = /^[A-Z][A-Z0-9+.-]*:/i;

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
 * The folder a nested file's package starts at: the folder holding its
 * `.claude`, or a nested CLAUDE.md's own folder. Undefined for a file at the
 * project root.
 */
const packageFolder = (fromFile: string): string | undefined => {
  const match = PACKAGE_FOLDER.exec(fromFile);

  return match?.[1] ?? match?.[2];
};

/**
 * A path in the package folder. Resolving against it with the `file-dir` base
 * tries the package root without widening the context contract.
 */
const packageAnchor = (fromFile: string): string | undefined => {
  const folder = packageFolder(fromFile);

  return folder === undefined ? undefined : `${folder}/_`;
};

// An extensionless token is often an import specifier (`test/mocks/database`),
// which names a source module without its extension. A candidate built from it
// can only find the file: it never decides whether the token is dead or outside.
const SPECIFIER_EXTENSIONS = ['ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs'];

const specifierCandidates = (token: string): string[] =>
  token.endsWith('/') || EXTENSION.test(token.split('/').pop() ?? '') ?
    []
  : SPECIFIER_EXTENSIONS.map((extension) => `${token}.${extension}`);

export type ReferenceStatus =
  | {relative: string; status: 'dead'}
  | {relative: string; status: 'found'}
  | {status: 'outside'}
  | {status: 'unresolvable'};

type PathReferenceQuery = {
  /** Extra folders to try, each given as a file inside it; they can only find. */
  anchors?: readonly string[];
  bases: readonly ReferenceBase[];
  fromFile: string;
  token: string;
};

const resolveUnderBases = (
  context: RuleContext,
  {bases, fromFile}: PathReferenceQuery,
  candidate: string
): ResolvedPath[] =>
  bases.flatMap((base) => {
    if (base !== 'package') return [context.resolve(fromFile, candidate, base)];

    const anchor = packageAnchor(fromFile);

    return anchor === undefined ?
        []
      : [context.resolve(anchor, candidate, 'file-dir')];
  });

/** Every place `candidate` is tried for `reference`: its bases, then its anchors. */
const resolveEverywhere = (
  context: RuleContext,
  reference: PathReferenceQuery,
  candidate: string
): ResolvedPath[] => [
  ...resolveUnderBases(context, reference, candidate),
  ...(reference.anchors ?? []).map((anchor) =>
    context.resolve(anchor, candidate, 'file-dir')
  ),
];

/**
 * Paths GAIA's own tooling writes on first use, so a fresh tree lacks them and
 * no ignore file names them: `gaia init` writes its resume cursor, and the wiki
 * maintenance passes write their audit reports under `wiki/meta/`. Only the
 * folder is listed: a report's name varies, so a cited file under it is still
 * a claim that the file exists.
 */
const TOOLING_PATHS: ReadonlySet<string> = new Set([
  STATE_FILE_RELATIVE,
  'wiki/meta',
]);

/**
 * Whether a missing path is a runtime artifact a fresh clone lacks: one GAIA's
 * tooling creates, or one git ignores. `folder` keeps the trailing slash, which
 * a directory-only ignore pattern such as `output/` needs to match a folder
 * that does not exist.
 */
export const isRuntimeArtifact = (
  context: RuleContext,
  relative: string,
  folder: boolean
): boolean =>
  TOOLING_PATHS.has(relative) ||
  context.gitIgnored(folder ? `${relative}/` : relative) === true;

/**
 * Where a path token points. Anything found under any base or anchor counts as
 * found; otherwise a target that leaves the root under every base is `outside`,
 * never read and never dead. A runtime artifact absent from a fresh clone is
 * found rather than dead.
 */
export const resolveReference = (
  context: RuleContext,
  reference: PathReferenceQuery
): ReferenceStatus => {
  const {token} = reference;

  // A home-relative token leaves the project by construction; joining it to the
  // root would misread `~` as a folder name.
  if (token.startsWith('~')) return {status: 'outside'};

  for (const candidate of [token, ...specifierCandidates(token)]) {
    const found = resolveEverywhere(context, reference, candidate).find(
      (result) => result.status === 'inside' && result.exists
    );

    if (found?.status === 'inside') {
      return {relative: found.relative, status: 'found'};
    }
  }

  // Only the bases decide outside and dead; an anchor can only find.
  const underBases = resolveUnderBases(context, reference, token);

  if (
    underBases.length > 0 &&
    underBases.every((result) => result.status === 'outside')
  ) {
    return {status: 'outside'};
  }

  const inside = underBases.find((result) => result.status === 'inside');

  if (inside?.status !== 'inside') return {status: 'unresolvable'};

  if (isRuntimeArtifact(context, inside.relative, token.endsWith('/'))) {
    return {relative: inside.relative, status: 'found'};
  }

  return {relative: inside.relative, status: 'dead'};
};

const folderSets = new WeakMap<ReadonlySet<string>, ReadonlySet<string>>();

/** Every folder that holds a tracked path, built once per project. */
const trackedFolders = (context: RuleContext): ReadonlySet<string> => {
  const cached = folderSets.get(context.allTrackedPaths);

  if (cached !== undefined) return cached;

  const folders = new Set<string>();

  for (const tracked of context.allTrackedPaths) {
    const segments = tracked.split('/');

    for (let end = 1; end < segments.length; end += 1) {
      folders.add(segments.slice(0, end).join('/'));
    }
  }

  folderSets.set(context.allTrackedPaths, folders);

  return folders;
};

/**
 * Whether a resolved place is a real folder: one holding a tracked file, or an
 * ignored one. Matched against the tracked names, so a case-insensitive disk
 * does not let `Pages/` stand for `pages/`.
 */
export const isProjectFolder = (
  context: RuleContext,
  resolved: ResolvedPath
): boolean =>
  resolved.status === 'inside' &&
  (trackedFolders(context).has(resolved.relative) ||
    context.gitIgnored(resolved.relative) === true);

const GLOB_SEGMENT = /[*?[\]{}!]/;

/**
 * The folders a rule's `paths:` globs scope it to, each given as a file inside
 * it: the static prefix of every glob, under the rule's package. A rule about
 * `app/**` names `components/ui/` relative to `app/`.
 */
const scopeAnchors = (file: ProjectFile): string[] => {
  const frontmatter = splitFrontmatter(file.text);

  if (!frontmatter.ok) return [];

  const declared: unknown = frontmatter.data.paths;
  const globs: unknown[] =
    Array.isArray(declared) ? declared
    : declared === undefined ? []
    : [declared];
  const folder = packageFolder(file.path);

  return globs.flatMap((glob) => {
    if (typeof glob !== 'string') return [];

    const segments = glob.split('/');
    const firstGlob = segments.findIndex((segment) =>
      GLOB_SEGMENT.test(segment)
    );
    const prefix = segments
      .slice(0, firstGlob === -1 ? segments.length - 1 : firstGlob)
      .join('/');

    if (prefix === '') return [];

    return [folder === undefined ? `${prefix}/_` : `${folder}/${prefix}/_`];
  });
};

const PLACEHOLDER = /<[^<>]+>/;

/**
 * Whether a token is a worked example of a placeholder template `text`
 * declares, such as `pages/about/page.tsx` beside `pages/<route>/page.tsx`; a
 * placeholder stands for any run of path characters, folders included. Both
 * the first and the last segment must be literal: a placeholder there (`<x>/a`,
 * `a/<x>/`, `a/<x>.md`) fits every path in some folder, so it would silence
 * every dead path under it and declares no example.
 */
export const templateExamples = (
  text: string
): ((token: string) => boolean) => {
  const templates =
    text.includes('<') ?
      bodyLines(text).flatMap((line) =>
        [...line.matchAll(BACKTICKED)].flatMap((match) => {
          const template = match[1] ?? '';
          const literals = template.split(PLACEHOLDER);
          const segments = template.replace(/\/$/, '').split('/');

          if (
            literals.length < 2 ||
            (segments[0] ?? '').includes('<') ||
            (segments.at(-1) ?? '').includes('<') ||
            !literals.every(
              (literal) => literal === '' || PATH_CHARACTERS.test(literal)
            )
          ) {
            return [];
          }

          const pattern = literals
            .map((literal) => escapeRegExp(literal))
            .join(String.raw`[\w./@+-]+`);

          return [new RegExp(`^${pattern}$`)];
        })
      )
    : [];

  return (token) => templates.some((template) => template.test(token));
};

/**
 * One finding per backticked or linked path in `files` that does not exist.
 * A path is also tried from the package a nested file belongs to and from a
 * rule's `paths:` scope. A link is always a claim that a file exists. A
 * backticked token is one only when it locates something: it has a folder,
 * and that first folder exists under some base it is tried against. A bare
 * name, a lint rule id, a package subpath, a placeholder and a title all fail
 * that, and a bare name that is missing cannot be told from an example, a
 * runtime file or a sentence saying the file does not exist. The cost is a
 * backticked path whose whole top folder was removed, which goes unreported.
 * Nor is a backticked instance of a placeholder template the same file
 * declares a claim: it is a worked example of that template.
 */
export const deadPathFindings = (
  context: RuleContext,
  files: readonly ProjectFile[]
): RawFinding[] =>
  files.flatMap((file) => {
    const anchors = scopeAnchors(file);
    const isExample = templateExamples(file.text);

    return extractPathReferences(file.text).flatMap(({line, linked, token}) => {
      const segments = token.replace(/\/$/, '').split('/');

      if (!linked && segments.length === 1) return [];

      if (!linked && isExample(token)) return [];

      const reference: PathReferenceQuery = {
        anchors,
        bases: linked ? ['root', 'file-dir', 'package'] : ['root', 'package'],
        fromFile: file.path,
        token,
      };
      if (resolveReference(context, reference).status !== 'dead') return [];

      if (
        !linked &&
        !resolveEverywhere(context, reference, segments[0] ?? '').some(
          (resolved) => isProjectFolder(context, resolved)
        )
      ) {
        return [];
      }

      return [
        {
          file: file.path,
          line,
          message: `The path ${token} does not exist.`,
          remediation:
            'Update the path to where the file lives now, or remove the reference.',
        },
      ];
    });
  });
