import path from 'node:path';
import type {RuleContext} from './context.js';
import {stripFencedCode} from './markdown.js';
import type {FileKind, ProjectFile} from './types.js';

export type DepthViolation = {
  file: string;
  line: number;
  target: string;
};

export type LinkEdge = {
  from: string;
  line: number;
  to: string;
};

export type LinkGraph = {
  /** Level 1: files an entry links, plus siblings of a level 1 file that it links. */
  levelOne: ReadonlySet<string>;
  /** Level 0: entry files. */
  levelZero: ReadonlySet<string>;
  /** Targets linked by a level 0 or level 1 file. */
  linked: ReadonlySet<string>;
  violations: readonly DepthViolation[];
};

export type LinkReference = {
  kind: 'backtick' | 'markdown';
  line: number;
  target: string;
};

const MARKDOWN_LINK = /\]\(<?([^)\s>]+)/g;
const BACKTICK_SPAN = /`([^`\n]+)`/g;
const URL_SCHEME = /^[A-Z][A-Z0-9+.-]*:/i;
const NOT_A_PATH = /[\s<>{}*?$|;&"'()\\]/;

/** A token that could be a relative file path: no placeholders, globs or URLs. */
const isRelativePathToken = (token: string): boolean =>
  token !== '' &&
  !token.startsWith('/') &&
  !token.startsWith('~') &&
  !token.startsWith('#') &&
  !URL_SCHEME.test(token) &&
  !NOT_A_PATH.test(token);

const withoutFragment = (token: string): string => {
  const cut = token.search(/[#?]/);

  return cut === -1 ? token : token.slice(0, cut);
};

/** Every markdown link and backticked relative path outside fenced code, with its line. */
export const extractLinks = (text: string): LinkReference[] => {
  const found: LinkReference[] = [];
  const lines = stripFencedCode(text).split('\n');

  for (const [index, line] of lines.entries()) {
    for (const match of line.matchAll(MARKDOWN_LINK)) {
      const target = withoutFragment(match[1] ?? '');

      if (isRelativePathToken(target)) {
        found.push({kind: 'markdown', line: index + 1, target});
      }
    }

    for (const match of line.matchAll(BACKTICK_SPAN)) {
      const target = withoutFragment((match[1] ?? '').trim());

      if (isRelativePathToken(target)) {
        found.push({kind: 'backtick', line: index + 1, target});
      }
    }
  }

  return found;
};

const SKILL_DIRECTORY = /^((?:.*\/)?\.claude\/skills\/[^/]+)\//;

/** The skill directory a file lives under, or undefined for a file outside one. */
export const skillDirectoryOf = (relative: string): string | undefined =>
  SKILL_DIRECTORY.exec(relative)?.[1];

type LinkAttempt = {base: 'file-dir' | 'root'; from: string};

/** The directories a relative target is tried against, in order. */
const linkAttempts = (
  fromFile: string,
  reference: LinkReference
): LinkAttempt[] => {
  const skillDirectory = skillDirectoryOf(fromFile);
  const attempts: LinkAttempt[] = [{base: 'file-dir', from: fromFile}];

  if (reference.kind === 'backtick') {
    attempts.push({base: 'root', from: fromFile});

    if (skillDirectory !== undefined) {
      attempts.push({base: 'file-dir', from: `${skillDirectory}/SKILL.md`});
    }
  }

  return attempts;
};

export type LinkResolution =
  | {relative: string; status: 'found'}
  | {status: 'dead' | 'ignored' | 'outside'};

/**
 * Resolves every place a target is tried exactly once and classifies it. A
 * target on disk is found. Otherwise one the VCS ignores is a runtime artifact
 * a fresh clone does not have, so it is not a broken link. Otherwise one that
 * leaves the project root (a link out of the repository, or a folder symlinked
 * elsewhere such as a shared state folder in a linked worktree) is never read
 * or judged. Anything else is dead.
 */
export const resolveLink = (
  context: RuleContext,
  fromFile: string,
  reference: LinkReference
): LinkResolution => {
  let ignored = false;
  let outside = false;

  for (const attempt of linkAttempts(fromFile, reference)) {
    const resolved = context.resolve(
      attempt.from,
      reference.target,
      attempt.base
    );

    if (resolved.status === 'outside') {
      outside = true;
    } else if (resolved.status === 'inside') {
      if (resolved.exists) {
        return {relative: resolved.relative, status: 'found'};
      }

      if (context.gitIgnored(resolved.relative) === true) ignored = true;
    }
  }

  if (ignored) return {status: 'ignored'};

  return {status: outside ? 'outside' : 'dead'};
};

export const resolveLinkTarget = (
  context: RuleContext,
  fromFile: string,
  reference: LinkReference
): string | undefined => {
  const resolution = resolveLink(context, fromFile, reference);

  return resolution.status === 'found' ? resolution.relative : undefined;
};

const GRAPH_KINDS: readonly FileKind[] = [
  'skill',
  'command',
  'agent',
  'reference',
  'playbook',
];

const hasKind = (file: ProjectFile, kinds: readonly FileKind[]): boolean =>
  kinds.some((kind) => file.kinds.includes(kind));

const REFERENCE_KINDS: readonly FileKind[] = ['reference', 'playbook'];

type EdgeMap = ReadonlyMap<string, readonly LinkEdge[]>;

const collectEdges = (
  context: RuleContext,
  nodes: readonly ProjectFile[]
): EdgeMap => {
  const edgesFrom = new Map<string, LinkEdge[]>();

  for (const file of nodes) {
    const edges: LinkEdge[] = [];

    for (const reference of extractLinks(file.text)) {
      const to = resolveLinkTarget(context, file.path, reference);

      if (to !== undefined && to !== file.path) {
        edges.push({from: file.path, line: reference.line, to});
      }
    }

    edgesFrom.set(file.path, edges);
  }

  return edgesFrom;
};

/** Level 1: what an entry links, then siblings a level 1 file links, until stable. */
const collectLevelOne = (
  edgesFrom: EdgeMap,
  levelZero: ReadonlySet<string>,
  referenceFiles: ReadonlySet<string>
): Set<string> => {
  const levelOne = new Set<string>();
  const queue = [...levelZero];

  for (const file of queue) {
    const fromEntry = levelZero.has(file);

    for (const edge of edgesFrom.get(file) ?? []) {
      const reachable =
        fromEntry || path.posix.dirname(edge.to) === path.posix.dirname(file);

      if (
        reachable &&
        referenceFiles.has(edge.to) &&
        !levelZero.has(edge.to) &&
        !levelOne.has(edge.to)
      ) {
        levelOne.add(edge.to);
        queue.push(edge.to);
      }
    }
  }

  return levelOne;
};

/**
 * Builds the reference graph the depth and orphan rules read.
 *
 * Entry files (level 0) are each SKILL.md, each command, and each playbook a
 * command routes to. A file an entry links is level 1. A level 1 file may link
 * its siblings (same directory) and they stay level 1. Any other file a level 1
 * file links is a depth violation on the linking line.
 */
export const buildLinkGraph = (context: RuleContext): LinkGraph => {
  const nodes = context.files.filter((file) => hasKind(file, GRAPH_KINDS));
  const referenceFiles = new Set(
    nodes
      .filter((file) => hasKind(file, REFERENCE_KINDS))
      .map((file) => file.path)
  );
  const edgesFrom = collectEdges(context, nodes);
  const levelZero = new Set(
    nodes
      .filter((file) => hasKind(file, ['skill', 'command', 'playbook']))
      .map((file) => file.path)
  );
  const levelOne = collectLevelOne(edgesFrom, levelZero, referenceFiles);

  const violations: DepthViolation[] = [];
  const linked = new Set<string>();

  for (const file of [...levelZero, ...levelOne]) {
    for (const edge of edgesFrom.get(file) ?? []) {
      linked.add(edge.to);

      const placed = levelZero.has(edge.to) || levelOne.has(edge.to);

      if (levelOne.has(file) && referenceFiles.has(edge.to) && !placed) {
        violations.push({file, line: edge.line, target: edge.to});
      }
    }
  }

  return {levelOne, levelZero, linked, violations};
};
