import {existsSync, realpathSync, statSync} from 'node:fs';
import path from 'node:path';
import {execGaiaGitRaw} from '../util/git-env.js';
import {compareBytes} from './markdown.js';
import type {FileKind, ModelFamily, ProjectFile} from './types.js';

export type ContextInput = {
  allTrackedPaths: ReadonlySet<string>;
  files: readonly ProjectFile[];
  inGit: boolean;
  knownRuleIds: ReadonlySet<string>;
  projectModel: ModelFamily;
  root: string;
};

export type ResolvedPath =
  | {exists: boolean; relative: string; status: 'inside'}
  | {status: 'invalid'}
  | {status: 'outside'};

export type RuleContext = {
  /** Every path found through git (or the walk outside git), any ownership. */
  allTrackedPaths: ReadonlySet<string>;
  /** Linted files only: adopter, gaia-shipped or unknown. */
  files: readonly ProjectFile[];
  filesOfKind: (kind: FileKind) => readonly ProjectFile[];
  /** The discovered root fitness config, when it is linted. */
  fitnessConfig: SettingsFile | undefined;
  /** `git check-ignore -q`; undefined outside git. */
  gitIgnored: (relative: string) => boolean | undefined;
  isExecutable: (relative: string) => boolean;
  /** Every id and alias a suppression may name. */
  knownRuleIds: ReadonlySet<string>;
  /** Root `.claude/settings.json` `model`, else `unresolved`. */
  projectModel: ModelFamily;
  resolve: (
    fromFile: string,
    target: string,
    base: 'file-dir' | 'root'
  ) => ResolvedPath;
  /** Absolute. Only for calling existing primitives; never put in a finding. */
  rootDirectory: string;
  /** Every linted `**\/.claude/settings.json` and `settings.local.json`. */
  settingsFiles: readonly SettingsFile[];
};

export type SettingsFile = {
  parsed: unknown;
  parseError: string | undefined;
  path: string;
  text: string;
};

export const parseJsonFile = (relative: string, text: string): SettingsFile => {
  try {
    return {
      parsed: JSON.parse(text) as unknown,
      parseError: undefined,
      path: relative,
      text,
    };
  } catch (error: unknown) {
    return {
      parsed: undefined,
      parseError: error instanceof Error ? error.message : String(error),
      path: relative,
      text,
    };
  }
};

const realpathOfDeepestExisting = (absolute: string): string => {
  let current = absolute;
  const remainder: string[] = [];

  for (;;) {
    try {
      return path.join(realpathSync(current), ...remainder.toReversed());
    } catch {
      const parent = path.dirname(current);

      if (parent === current) return absolute;
      remainder.push(path.basename(current));
      current = parent;
    }
  }
};

/** Whether `real` (already a real path) is `realRoot` or lies under it. */
export const isInsideRoot = (realRoot: string, real: string): boolean => {
  const relative = path.relative(realRoot, real);

  return (
    relative === '' ||
    (!relative.startsWith('..') && !path.isAbsolute(relative))
  );
};

/** The linted files carrying any of `kinds`, in `context.files` order. */
export const filesOfKinds = (
  context: RuleContext,
  kinds: readonly FileKind[]
): readonly ProjectFile[] =>
  context.files.filter((file) =>
    file.kinds.some((kind) => kinds.includes(kind))
  );

const toPosix = (value: string): string => value.split(path.sep).join('/');

/** Builds the read-only view every rule receives. */
export const createRuleContext = (input: ContextInput): RuleContext => {
  const {allTrackedPaths, files, inGit, knownRuleIds, projectModel, root} =
    input;
  const byKind = new Map<FileKind, ProjectFile[]>();

  for (const file of files) {
    for (const kind of file.kinds) {
      const list = byKind.get(kind);

      if (list) list.push(file);
      else byKind.set(kind, [file]);
    }
  }

  const filesOfKind = (kind: FileKind): readonly ProjectFile[] =>
    byKind.get(kind) ?? [];

  const settingsCandidates = [
    ...filesOfKind('settings'),
    ...filesOfKind('settings-local'),
  ];
  const settingsFiles = settingsCandidates
    .toSorted((a, b) => compareBytes(a.path, b.path))
    .map((file) => parseJsonFile(file.path, file.text));

  const configFile = filesOfKind('fitness-config')[0];
  const realRoot = realpathOfDeepestExisting(root);

  const resolve: RuleContext['resolve'] = (fromFile, target, base) => {
    if (target === '' || target.includes('\0')) return {status: 'invalid'};

    const baseDirectory =
      base === 'root' ? root : path.join(root, path.posix.dirname(fromFile));
    const absolute = path.resolve(baseDirectory, target);
    const real = realpathOfDeepestExisting(absolute);

    if (!isInsideRoot(realRoot, real)) return {status: 'outside'};

    const relative = path.relative(realRoot, real);

    return {
      exists: existsSync(absolute),
      relative: toPosix(relative),
      status: 'inside',
    };
  };

  const isExecutable: RuleContext['isExecutable'] = (relative) => {
    try {
      // eslint-disable-next-line no-bitwise -- the mode is a bit field; 0o111 masks the execute bits
      return (statSync(path.join(root, relative)).mode & 0o111) !== 0;
    } catch {
      return false;
    }
  };

  const ignoredCache = new Map<string, boolean | undefined>();

  const gitIgnored: RuleContext['gitIgnored'] = (relative) => {
    if (!inGit) return undefined;
    if (ignoredCache.has(relative)) return ignoredCache.get(relative);

    let answer: boolean | undefined;

    try {
      execGaiaGitRaw(['-C', root, 'check-ignore', '-q', '--', relative], root);
      answer = true;
    } catch (error: unknown) {
      answer = (error as {status?: number}).status === 1 ? false : undefined;
    }

    ignoredCache.set(relative, answer);

    return answer;
  };

  return {
    allTrackedPaths,
    files,
    filesOfKind,
    fitnessConfig:
      configFile === undefined ? undefined : (
        parseJsonFile(configFile.path, configFile.text)
      ),
    gitIgnored,
    isExecutable,
    knownRuleIds,
    projectModel,
    resolve,
    rootDirectory: root,
    settingsFiles,
  };
};
