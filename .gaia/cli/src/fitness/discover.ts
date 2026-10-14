import {readdirSync, readFileSync, realpathSync, statSync} from 'node:fs';
import path from 'node:path';
import {execGaiaGitRaw} from '../util/git-env.js';
import {gitZArgs, splitZStream} from '../util/git-z.js';
import {FITNESS_CONFIG_PATH} from './config.js';
import {isInsideRoot} from './context.js';
import {compareBytes, splitFrontmatter} from './markdown.js';
import type {FileKind} from './types.js';

export type DiscoveredFile = {
  kinds: readonly FileKind[];
  path: string;
  text: string;
};

export type Discovery = {
  /** Every path found through git, or the walk outside git; excludes on-disk local files. */
  allTrackedPaths: ReadonlySet<string>;
  files: readonly DiscoveredFile[];
  inGit: boolean;
};

/** The depth a CLAUDE.md or CLAUDE.local.md is discovered at, counted in path segments. */
const MAX_CLAUDE_MD_SEGMENTS = 3;

const SETTINGS_LOCAL_PATH = '.claude/settings.local.json';

const SKIPPED_DIRECTORIES: ReadonlySet<string> = new Set([
  '.git',
  'node_modules',
]);

const isUnderWorktrees = (relative: string): boolean =>
  relative === '.claude/worktrees' ||
  relative.startsWith('.claude/worktrees/') ||
  relative.includes('/.claude/worktrees/');

const isSkipped = (relative: string): boolean =>
  isUnderWorktrees(relative) ||
  relative.split('/').some((segment) => SKIPPED_DIRECTORIES.has(segment));

const SKILL_FILE = /(?:^|\/)\.claude\/skills\/[^/]+\/SKILL\.md$/;
const SKILL_TREE_MARKDOWN = /(?:^|\/)\.claude\/skills\/[^/]+\/.+\.md$/;
const COMMAND_FILE = /(?:^|\/)\.claude\/commands\/.+\.md$/;
const AGENT_FILE = /(?:^|\/)\.claude\/agents\/.+\.md$/;
const RULE_FILE = /(?:^|\/)\.claude\/rules\/.+\.md$/;
const SETTINGS_FILE = /(?:^|\/)\.claude\/settings\.json$/;
const SETTINGS_LOCAL_FILE = /(?:^|\/)\.claude\/settings\.local\.json$/;

/** The kinds a path earns from its name alone; a playbook and a real agent are decided by content. */
export const kindsOfPath = (relative: string): FileKind[] => {
  const kinds: FileKind[] = [];
  const segments = relative.split('/');
  const base = segments.at(-1);

  if (SKILL_FILE.test(relative)) kinds.push('skill');
  else if (SKILL_TREE_MARKDOWN.test(relative)) kinds.push('reference');

  if (COMMAND_FILE.test(relative)) kinds.push('command');
  if (RULE_FILE.test(relative)) kinds.push('rule');

  if (segments.length <= MAX_CLAUDE_MD_SEGMENTS) {
    if (base === 'CLAUDE.md') kinds.push('claudemd');
    if (base === 'CLAUDE.local.md') kinds.push('claudemd-local');
  }

  if (relative.startsWith('wiki/') && relative.endsWith('.md')) {
    kinds.push('wiki');
  }

  if (SETTINGS_FILE.test(relative)) kinds.push('settings');
  if (SETTINGS_LOCAL_FILE.test(relative)) kinds.push('settings-local');
  if (relative === FITNESS_CONFIG_PATH) kinds.push('fitness-config');

  return kinds;
};

/**
 * Claude Code scans `.claude/agents/` recursively but treats a file with no
 * frontmatter, or frontmatter with no `name`, as documentation beside the
 * agents. Broken frontmatter stays an agent, because Claude Code drops it
 * silently and the author meant one.
 */
export const isAgentDocumentation = (text: string): boolean => {
  const frontmatter = splitFrontmatter(text);

  if (frontmatter.error === 'no frontmatter') return true;

  if (!frontmatter.ok) return false;

  const {name} = frontmatter.data;

  return (
    name === undefined ||
    name === null ||
    (typeof name === 'string' && name.trim() === '')
  );
};

const listGitTracked = (root: string): string[] | undefined => {
  try {
    return splitZStream(
      execGaiaGitRaw(['-C', root, ...gitZArgs('ls-files', ['--cached'])], root)
    );
  } catch {
    return undefined;
  }
};

const walkTree = (root: string): string[] => {
  const found: string[] = [];

  const visit = (relativeDirectory: string): void => {
    const absolute = path.join(root, relativeDirectory);

    for (const entry of readdirSync(absolute, {withFileTypes: true})) {
      const relative =
        relativeDirectory === '' ?
          entry.name
        : `${relativeDirectory}/${entry.name}`;

      if (entry.isDirectory()) {
        if (!isSkipped(relative)) visit(relative);
      } else if (entry.isFile()) {
        found.push(relative);
      }
    }
  };

  visit('');

  return found;
};

const realpathOrSelf = (target: string): string => {
  try {
    return realpathSync(target);
  } catch {
    return target;
  }
};

const isRegularFileInside = (
  root: string,
  realRoot: string,
  relative: string
): boolean => {
  const absolute = path.join(root, relative);

  try {
    // A symlink may point anywhere, and a macOS temp root is itself reached
    // through a symlink, so both ends are compared as real paths.
    const real = realpathSync(absolute);

    if (!statSync(real).isFile()) return false;

    return isInsideRoot(realRoot, real);
  } catch {
    return false;
  }
};

const subdirectories = (root: string, directory: string): string[] => {
  try {
    return readdirSync(path.join(root, directory), {withFileTypes: true})
      .filter((entry) => entry.isDirectory())
      .map((entry) =>
        directory === '' ? entry.name : `${directory}/${entry.name}`
      )
      .filter((relative) => !isSkipped(relative));
  } catch {
    return [];
  }
};

const directoriesBelow = (root: string, depth: number): string[] => {
  const collected: string[] = [];
  let frontier = [''];

  for (let level = 0; level < depth; level += 1) {
    frontier = frontier.flatMap((directory) => subdirectories(root, directory));
    collected.push(...frontier);
  }

  return collected;
};

/**
 * Files Claude Code loads that the repository normally leaves untracked. They
 * are linted but kept out of `allTrackedPaths`, so a clean checkout reports the
 * same tracked set on every machine.
 */
const findOnDiskLocalFiles = (root: string, realRoot: string): string[] => {
  const directories = [
    '',
    ...directoriesBelow(root, MAX_CLAUDE_MD_SEGMENTS - 1),
  ];
  const candidates = [
    SETTINGS_LOCAL_PATH,
    ...directories.map((directory) =>
      directory === '' ? 'CLAUDE.local.md' : `${directory}/CLAUDE.local.md`
    ),
  ];

  return candidates.filter((relative) =>
    isRegularFileInside(root, realRoot, relative)
  );
};

const READ_TARGET = /\bRead\s+`([^`\n]+)`/g;

const PLAYBOOK_ROOTS = ['.claude/', 'frontend/.claude/'] as const;

const playbookTargets = (
  routing: DiscoveredFile,
  tracked: ReadonlySet<string>
): string[] => {
  const routingDirectory = path.posix.dirname(routing.path);
  const mentioned = Array.from(
    routing.text.matchAll(READ_TARGET),
    (match) => match[1]?.trim() ?? ''
  ).filter((raw) => raw.endsWith('.md') && !path.isAbsolute(raw));

  return mentioned.flatMap((raw) => {
    const fromRoot = path.posix.normalize(raw);
    const fromRouting = path.posix.normalize(
      path.posix.join(routingDirectory, raw)
    );
    const resolved = [fromRoot, fromRouting].find(
      (candidate) =>
        !candidate.startsWith('..') &&
        PLAYBOOK_ROOTS.some((prefix) => candidate.startsWith(prefix)) &&
        tracked.has(candidate)
    );

    return resolved === undefined ? [] : [resolved];
  });
};

const sortedKinds = (kinds: Iterable<FileKind>): FileKind[] => {
  const unique = [...new Set(kinds)];

  return unique.toSorted(compareBytes);
};

/**
 * Finds every file the linter reads under `root`.
 *
 * Inside git that is tracked files only, so an untracked scratch file never
 * changes a result; outside git it is a walk. Two on-disk local files are the
 * exception, because Claude Code loads them though they are normally untracked.
 */
export const discoverFiles = (root: string): Discovery => {
  const tracked = listGitTracked(root);
  const inGit = tracked !== undefined;
  const listed = (tracked ?? walkTree(root)).filter(
    (relative) => !isSkipped(relative)
  );
  const realRoot = realpathOrSelf(root);
  const existing = listed.filter((relative) =>
    isRegularFileInside(root, realRoot, relative)
  );
  const localCandidates = findOnDiskLocalFiles(root, realRoot);
  const listedSet = new Set(existing);
  const localOnly = localCandidates.filter(
    (relative) => !listedSet.has(relative)
  );

  const textByPath = new Map<string, string>();

  const readText = (relative: string): string => {
    const cached = textByPath.get(relative);

    if (cached !== undefined) return cached;

    const text = readFileSync(path.join(root, relative), 'utf8');

    textByPath.set(relative, text);

    return text;
  };

  const kindsByPath = new Map<string, FileKind[]>();

  for (const relative of [...existing, ...localOnly]) {
    const kinds = kindsOfPath(relative);

    if (
      AGENT_FILE.test(relative) &&
      !isAgentDocumentation(readText(relative))
    ) {
      kinds.push('agent');
    }

    if (kinds.length > 0) kindsByPath.set(relative, kinds);
  }

  const routingFiles: DiscoveredFile[] = [...kindsByPath.entries()]
    .filter(([, kinds]) => kinds.includes('command') || kinds.includes('skill'))
    .map(([relative, kinds]) => ({
      kinds,
      path: relative,
      text: readText(relative),
    }));

  for (const routing of routingFiles) {
    for (const target of playbookTargets(routing, listedSet)) {
      kindsByPath.set(target, [...(kindsByPath.get(target) ?? []), 'playbook']);
    }
  }

  const files: DiscoveredFile[] = [...kindsByPath.entries()]
    .map(([relative, kinds]) => ({
      kinds: sortedKinds(kinds),
      path: relative,
      text: readText(relative),
    }))
    .toSorted((a, b) => compareBytes(a.path, b.path));

  const localPatternPaths = new Set(localCandidates);
  const allTrackedPaths = new Set(
    inGit ? existing : (
      existing.filter((relative) => !localPatternPaths.has(relative))
    )
  );

  return {allTrackedPaths, files, inGit};
};

/** `hasPathScope` over frontmatter the caller already split. */
export const hasPathScopeIn = ({
  data,
  ok,
}: ReturnType<typeof splitFrontmatter>): boolean => {
  if (!ok) return false;

  const {paths} = data;

  if (typeof paths === 'string') return paths.trim() !== '';

  return Array.isArray(paths) && paths.length > 0;
};

/** True only for a rule whose frontmatter `paths:` is a non-empty string or list. */
export const hasPathScope = (text: string): boolean =>
  hasPathScopeIn(splitFrontmatter(text));
