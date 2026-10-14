import {lstatSync, readdirSync, readFileSync, statSync} from 'node:fs';
import type {Dirent} from 'node:fs';
import {homedir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {defaultRoot, parseRootArguments} from './cli-args.js';
import {compareBytes, stripFencedCode} from './markdown.js';
import {BACKTICKED, LINE_SUFFIX} from './paths.js';
import {INVENTORY_ONLY_RULES} from './rules/index.js';
import {redactDeep} from './secrets.js';
import type {Severity} from './types.js';

export const STORE_NAMES = [
  'memory',
  'user_agent_memory',
  'project_agent_memory',
  'rules',
  'wiki',
  'claude_md',
] as const;

export type InventoryFile = {
  lines: number;
  mtime: number;
  path: string;
  words: number;
};

export type InventoryFinding = {
  category: 'memory';
  file: string;
  line: number;
  message: string;
  remediation: string;
  rule_id: string;
  severity: Severity;
};

export type InventoryReport = {
  findings: readonly InventoryFinding[];
  stores: Readonly<
    Record<StoreName, {count: number; files: readonly InventoryFile[]}>
  >;
};

export type StoreName = (typeof STORE_NAMES)[number];

/** `CLAUDE.md` is looked for at most this many path segments below the root. */
const CLAUDE_MD_MAX_DEPTH = 3;

const SKIPPED_DIRECTORIES: ReadonlySet<string> = new Set([
  '.git',
  'node_modules',
]);

const WORKTREES_DIRECTORY = '.claude/worktrees';

const DEAD_PATH_RULE = (() => {
  const rule = INVENTORY_ONLY_RULES.find(
    (candidate) => candidate.ruleId === 'memory.dead-path'
  );

  if (rule === undefined) throw new Error('memory.dead-path is not cataloged');

  return rule;
})();

/** How Claude Code keys a project's memory directory: every other character becomes a dash. */
export const memoryKey = (root: string): string =>
  root.replaceAll(/[^\dA-Za-z-]/g, '-');

const isDirectoryNotLink = (directory: string): boolean => {
  try {
    return lstatSync(directory).isDirectory();
  } catch {
    return false;
  }
};

type WalkOptions = {
  matches: (entry: Dirent) => boolean;
  maximumDepth: number;
  skipDirectory: (relative: string, entry: Dirent) => boolean;
};

type WalkPosition = {depth: number; prefix: string};

const WALK_START: WalkPosition = {depth: 1, prefix: ''};

/** Regular files below `directory` that match, never following a symbolic link. */
const walk = (
  directory: string,
  options: WalkOptions,
  position: WalkPosition
): string[] => {
  const {depth, prefix} = position;
  let entries: Dirent[];

  try {
    entries = readdirSync(directory, {withFileTypes: true});
  } catch {
    return [];
  }

  return entries.flatMap((entry) => {
    const relative = prefix === '' ? entry.name : `${prefix}/${entry.name}`;

    if (entry.isFile()) return options.matches(entry) ? [relative] : [];

    if (
      entry.isDirectory() &&
      depth < options.maximumDepth &&
      !options.skipDirectory(relative, entry)
    ) {
      return walk(path.join(directory, entry.name), options, {
        depth: depth + 1,
        prefix: relative,
      });
    }

    return [];
  });
};

const isMarkdown = (entry: Dirent): boolean => entry.name.endsWith('.md');

const markdownBelow = (directory: string): string[] =>
  isDirectoryNotLink(directory) ?
    walk(
      directory,
      {
        matches: isMarkdown,
        maximumDepth: Number.MAX_SAFE_INTEGER,
        skipDirectory: () => false,
      },
      WALK_START
    )
  : [];

const claudeMdBelow = (root: string): string[] =>
  walk(
    root,
    {
      matches: (entry) => entry.name === 'CLAUDE.md',
      maximumDepth: CLAUDE_MD_MAX_DEPTH,
      skipDirectory: (relative, entry) =>
        SKIPPED_DIRECTORIES.has(entry.name) || relative === WORKTREES_DIRECTORY,
    },
    WALK_START
  );

type StoreLocation = {
  /** The directory the store is read from. */
  directory: string;
  /** Prefix written before each store-relative path in the output. */
  label: string;
  relatives: readonly string[];
};

const locateStores = (
  root: string,
  home: string
): Readonly<Record<StoreName, StoreLocation>> => {
  const memoryDirectory = path.join(
    home,
    '.claude',
    'projects',
    memoryKey(root),
    'memory'
  );
  const userAgentDirectory = path.join(home, '.claude', 'agent-memory');
  const projectAgentDirectory = path.join(root, '.claude', 'agent-memory');
  const rulesDirectory = path.join(root, '.claude', 'rules');
  const wikiDirectory = path.join(root, 'wiki');

  return {
    claude_md: {
      directory: root,
      label: '',
      relatives: claudeMdBelow(root),
    },
    memory: {
      directory: memoryDirectory,
      label: '<memory>/',
      relatives: markdownBelow(memoryDirectory),
    },
    project_agent_memory: {
      directory: projectAgentDirectory,
      label: '.claude/agent-memory/',
      relatives: markdownBelow(projectAgentDirectory),
    },
    rules: {
      directory: rulesDirectory,
      label: '.claude/rules/',
      relatives: markdownBelow(rulesDirectory),
    },
    user_agent_memory: {
      directory: userAgentDirectory,
      label: '<agent-memory>/',
      relatives: markdownBelow(userAgentDirectory),
    },
    wiki: {
      directory: wikiDirectory,
      label: 'wiki/',
      relatives: markdownBelow(wikiDirectory),
    },
  };
};

type DescribedFile = {file: InventoryFile; text: string};

const describeFile = (
  location: StoreLocation,
  relative: string
): DescribedFile | undefined => {
  const absolute = path.join(location.directory, relative);

  try {
    const text = readFileSync(absolute, 'utf8');

    return {
      file: {
        lines: text.split('\n').length - 1,
        mtime: Math.floor(statSync(absolute).mtimeMs / 1000),
        path: `${location.label}${relative}`,
        words: (text.match(/\S+/g) ?? []).length,
      },
      text,
    };
  } catch {
    return undefined;
  }
};

const LINK_TARGET = /\]\(([^\s()]+)\)/g;
const SCHEME_OR_ABSOLUTE = /^(?:[A-Za-z][\d+.A-Za-z-]*:|[/~#])/;
const PLACEHOLDER = /[$*<>{}]/;
const FILE_EXTENSION = /\.[\dA-Za-z]{1,8}$/;

/** A repo-relative path a memory file cites, or undefined when the token is something else. */
const toRepoPath = (token: string): string | undefined => {
  const withoutAnchor = token.split('#', 1)[0] ?? '';
  const candidate = withoutAnchor.replace(LINE_SUFFIX, '').replace(/^\.\//, '');

  if (
    candidate === '' ||
    SCHEME_OR_ABSOLUTE.test(candidate) ||
    PLACEHOLDER.test(candidate) ||
    !candidate.includes('/') ||
    !FILE_EXTENSION.test(candidate) ||
    candidate.split('/').includes('..')
  ) {
    return undefined;
  }

  return candidate;
};

const pathExists = (root: string, relative: string): boolean => {
  try {
    statSync(path.join(root, relative));

    return true;
  } catch {
    return false;
  }
};

type CitedPath = {line: number; path: string};

const citedPaths = (text: string): CitedPath[] =>
  stripFencedCode(text)
    .split('\n')
    .flatMap((line, index) =>
      [...line.matchAll(BACKTICKED), ...line.matchAll(LINK_TARGET)].flatMap(
        (match) => {
          const cited = toRepoPath(match[1] ?? '');

          return cited === undefined ? [] : [{line: index + 1, path: cited}];
        }
      )
    );

const deadPathFindings = (
  root: string,
  described: readonly DescribedFile[]
): InventoryFinding[] =>
  described.flatMap(({file, text}) =>
    citedPaths(text)
      .filter((cited) => !pathExists(root, cited.path))
      .map((cited) => ({
        category: DEAD_PATH_RULE.category,
        file: file.path,
        line: cited.line,
        message: `The memory names \`${cited.path}\`, which does not exist in this project.`,
        remediation:
          'Update the memory to the path that exists now, or delete the entry if the file is gone for good.',
        rule_id: DEAD_PATH_RULE.ruleId,
        severity: DEAD_PATH_RULE.severity,
      }))
  );

/** The six knowledge stores under `root`, plus the dead paths the memory store cites. */
export const buildInventory = (root: string, home: string): InventoryReport => {
  const locations = locateStores(root, home);
  const describedByStore = Object.fromEntries(
    STORE_NAMES.map((name) => {
      const location = locations[name];
      const described = location.relatives
        .map((relative) => describeFile(location, relative))
        .filter((entry) => entry !== undefined);

      return [name, described] as const;
    })
  ) as Record<StoreName, DescribedFile[]>;
  const stores = Object.fromEntries(
    STORE_NAMES.map((name) => {
      const files = describedByStore[name]
        .map((entry) => entry.file)
        .toSorted((a, b) => compareBytes(a.path, b.path));

      return [name, {count: files.length, files}] as const;
    })
  ) as unknown as InventoryReport['stores'];
  const findings = deadPathFindings(root, describedByStore.memory).toSorted(
    (a, b) =>
      compareBytes(a.file, b.file) ||
      a.line - b.line ||
      compareBytes(a.message, b.message)
  );

  return {findings, stores};
};

export const run = (args: readonly string[]): number => {
  const parsed = parseRootArguments(args);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'fitness inventory',
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }

  const root = path.resolve(parsed.root ?? defaultRoot());

  try {
    if (!statSync(root).isDirectory()) throw new Error('not a directory');
  } catch {
    structuredError({
      code: 'could_not_run',
      message: 'the root is not a directory',
      subcommand: 'fitness inventory',
    });

    return EXIT_CODES.COULD_NOT_RUN;
  }

  const home = process.env.HOME ?? homedir();

  process.stdout.write(
    `${JSON.stringify(redactDeep(buildInventory(root, home)), null, 2)}\n`
  );

  return EXIT_CODES.OK;
};
