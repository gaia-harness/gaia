import {existsSync, realpathSync, statSync} from 'node:fs';
import path from 'node:path';
import {execGaiaGitRaw} from '../util/git-env.js';
import {splitZStream} from '../util/git-z.js';
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

/** `git check-ignore -q` exits 0 ignored, 1 not ignored, and 128 when git cannot answer. */
const checkIgnoreOne = (
  root: string,
  relative: string
): boolean | undefined => {
  try {
    execGaiaGitRaw(['-C', root, 'check-ignore', '-q', '--', relative], root);

    return true;
  } catch (error: unknown) {
    return (error as {status?: number}).status === 1 ? false : undefined;
  }
};

/**
 * The ignored subset of `paths` from one `git check-ignore --stdin -z`, which
 * echoes each ignored path exactly as it was given. Undefined when git cannot
 * answer: one path it rejects (empty, or beyond a symbolic link) aborts the
 * whole batch, and the caller then asks per path so only that path reads
 * undefined.
 */
const checkIgnoreBatch = (
  root: string,
  paths: readonly string[]
): ReadonlySet<string> | undefined => {
  try {
    const output = execGaiaGitRaw(
      ['-C', root, 'check-ignore', '--stdin', '-z'],
      root,
      paths.map((relative) => `${relative}\0`).join('')
    );

    return new Set(splitZStream(output));
  } catch (error: unknown) {
    return (error as {status?: number}).status === 1 ? new Set() : undefined;
  }
};

/**
 * Runs `run` (one rule's check) so its `gitIgnored` lookups cost one git
 * process per round instead of one per path. Each round answers every lookup
 * the cache cannot with a provisional `undefined` and records it; the recorded
 * paths are then answered in one batch and `run` goes again, until a round
 * misses nothing. Only that last round's result is returned, and every lookup
 * in it saw its real answer, so the result is the one a per-path run gives, on
 * the condition that `run` is a pure function of the context.
 */
export type BatchedRunner = <T>(run: () => Iterable<T>) => T[];

/** Builds the read-only view every rule receives, and the runner that batches its ignore lookups. */
export const createRuleContext = (
  input: ContextInput
): {context: RuleContext; runWithBatchedIgnores: BatchedRunner} => {
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
  let unanswered: Set<string> | undefined;

  // A batch git aborts is halved until the path it rejects stands alone, so
  // only that path pays a call of its own.
  const answerIgnored = (paths: readonly string[]): void => {
    const batch = checkIgnoreBatch(root, paths);

    if (batch !== undefined) {
      for (const relative of paths) {
        ignoredCache.set(relative, batch.has(relative));
      }
    } else if (paths.length === 1) {
      const [only] = paths as [string];

      ignoredCache.set(only, checkIgnoreOne(root, only));
    } else {
      const middle = Math.ceil(paths.length / 2);

      answerIgnored(paths.slice(0, middle));
      answerIgnored(paths.slice(middle));
    }
  };

  const gitIgnored: RuleContext['gitIgnored'] = (relative) => {
    if (!inGit) return undefined;
    if (ignoredCache.has(relative)) return ignoredCache.get(relative);

    if (unanswered !== undefined) {
      unanswered.add(relative);

      return undefined;
    }

    const answer = checkIgnoreOne(root, relative);

    ignoredCache.set(relative, answer);

    return answer;
  };

  const runWithBatchedIgnores: BatchedRunner = <T>(
    run: () => Iterable<T>
  ): T[] => {
    for (;;) {
      const missed = new Set<string>();
      let result: T[];

      unanswered = missed;

      try {
        result = [...run()];
      } finally {
        unanswered = undefined;
      }

      if (missed.size === 0) return result;
      answerIgnored([...missed]);
    }
  };

  const context: RuleContext = {
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

  return {context, runWithBatchedIgnores};
};
