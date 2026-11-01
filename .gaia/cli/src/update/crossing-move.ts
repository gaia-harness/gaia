/**
 * `gaia update crossing move`: moves the app to its new home and finishes the
 * edits that follow it. Every step applies only if it is still owed, so an
 * interrupted run, a hand-moved tree and a finished tree all end with the same
 * result as one uninterrupted run, and a second run changes nothing.
 *
 * Edits to JSON files are minimal text edits, so the adopter's formatting
 * survives. Only named paths are staged; the move never stages by wildcard.
 */
import {existsSync, mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {escapeRegExp} from '../util/escape-regexp.js';
import {execGaiaGit, execGaiaGitRaw} from '../util/git-env.js';
import {splitZStream} from '../util/git-z.js';
import {
  APPS_DIRECTORY,
  DESCRIPTOR_FILE,
  done,
  isDirectory,
  isSymlink,
  LEGACY_PACKAGE_NAME,
  LEGACY_PACKAGE_ROOT,
  NEW_PACKAGE_NAME,
  NEW_PACKAGE_ROOT,
  PACKAGES_DIRECTORY,
  readRegistry,
  readTextIfPresent,
  REGISTRY_FILE,
  reportLine,
  stop,
  topLevelOf,
  UPDATE_CACHE,
} from './crossing-shared.js';
import type {Outcome, RegistryEntry} from './crossing-shared.js';
import {editWorkspacePackages, matchedFolders} from './crossing-workspace.js';

const WORKSPACE_FILE = 'pnpm-workspace.yaml';
const IGNORED_RECORD = 'crossing-ignored.txt';
const KEEP_FILE = `${PACKAGES_DIRECTORY}/.gitkeep`;
const NEW_WORKSPACE = `packages:\n  - ${APPS_DIRECTORY}/*\n  - ${PACKAGES_DIRECTORY}/*\n`;

type Context = {lines: string[]; root: string; staged: Set<string>};

const topIndent = (text: string): string =>
  /^([\t ]+)"/mu.exec(text)?.[1] ?? '  ';

/** Sets the top-level `name` string by replacing only its value. */
const withName = (text: string, name: string): string => {
  const indent = escapeRegExp(topIndent(text));
  const pattern = new RegExp(
    String.raw`^(${indent}"name"\s*:\s*)"[^"]*"`,
    'mu'
  );

  return text.replace(pattern, (_match, head: string) => `${head}"${name}"`);
};

/** Appends one top-level property before the object's closing brace. */
const withProperty = (text: string, key: string, value: string): string => {
  const close = text.lastIndexOf('}');
  const body = text.slice(0, close).trimEnd();

  return `${body},\n${topIndent(text)}"${key}": ${value}\n${text.slice(close)}`;
};

const parseObject = (text: string): Record<string, unknown> | undefined => {
  try {
    const parsed: unknown = JSON.parse(text);

    return (
        typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
      ) ?
        (parsed as Record<string, unknown>)
      : undefined;
  } catch {
    return undefined;
  }
};

type FileEdit = {after: string; before: string | undefined; relative: string};

const writeIfChanged = (
  context: Context,
  {after, before, relative}: FileEdit
): boolean => {
  context.staged.add(relative);
  if (before === after) return false;
  mkdirSync(path.dirname(path.join(context.root, relative)), {recursive: true});
  writeFileSync(path.join(context.root, relative), after);

  return true;
};

const recordIgnored = (root: string): void => {
  const listing = splitZStream(
    execGaiaGitRaw(
      [
        '-c',
        'core.quotepath=false',
        'ls-files',
        '-z',
        '-o',
        '-i',
        '--exclude-standard',
        '--',
        `:(literal)${LEGACY_PACKAGE_ROOT}`,
      ],
      root
    )
  );
  const directory = path.join(root, UPDATE_CACHE);

  mkdirSync(directory, {recursive: true});
  writeFileSync(
    path.join(directory, IGNORED_RECORD),
    listing.map((entry) => `${entry}\n`).join('')
  );
};

/** Writes the registry for the new home; returns the member name that results. */
const updateRegistry = (context: Context): string | undefined => {
  const file = path.join(context.root, REGISTRY_FILE);
  const before = readTextIfPresent(file);
  const entries = readRegistry(context.root);
  const target = entries?.find(
    (entry) =>
      entry.path === LEGACY_PACKAGE_ROOT || entry.path === NEW_PACKAGE_ROOT
  );

  if (entries === undefined || target === undefined) return undefined;
  const original = {...target};

  target.path = NEW_PACKAGE_ROOT;
  if (target.name === LEGACY_PACKAGE_NAME) target.name = NEW_PACKAGE_NAME;
  const singleLine = !before?.trimEnd().includes('\n');
  const body =
    singleLine ? JSON.stringify(entries) : JSON.stringify(entries, null, 2);
  const after = `${body}\n`;

  if (writeIfChanged(context, {after, before, relative: REGISTRY_FILE})) {
    context.lines.push(
      reportLine(
        'registry',
        `${original.name} at ${original.path} is now ${target.name} at ${target.path}`
      )
    );
  }

  return target.name;
};

const updateDescriptor = (context: Context, memberName: string): void => {
  const relative = `${NEW_PACKAGE_ROOT}/${DESCRIPTOR_FILE}`;
  const before = readTextIfPresent(path.join(context.root, relative));
  const parsed = before === undefined ? undefined : parseObject(before);

  if (before === undefined || parsed === undefined) return;
  let after = before;

  if (parsed.name !== memberName) after = withName(after, memberName);
  if (parsed.stack === undefined) after = withProperty(after, 'stack', '"web"');
  if (parseObject(after) === undefined) return;

  if (writeIfChanged(context, {after, before, relative})) {
    context.lines.push(reportLine('descriptor', relative));
  }
};

const updatePackageName = (context: Context): void => {
  const relative = `${NEW_PACKAGE_ROOT}/package.json`;
  const before = readTextIfPresent(path.join(context.root, relative));
  const parsed = before === undefined ? undefined : parseObject(before);

  if (before === undefined || parsed?.name !== LEGACY_PACKAGE_NAME) return;
  const after = withName(before, NEW_PACKAGE_NAME);

  if (writeIfChanged(context, {after, before, relative})) {
    context.lines.push(reportLine('package-name', relative));
  }
};

const hasGeneratedSettings = (root: string, entry: RegistryEntry): boolean =>
  ['settings.json', 'settings.overlay.json'].some((name) =>
    existsSync(path.join(root, entry.path, '.claude', name))
  );

const markGeneratedSettings = (context: Context, appName: string): void => {
  for (const entry of readRegistry(context.root) ?? []) {
    const relative = path.posix.join(entry.path, DESCRIPTOR_FILE);
    const before = readTextIfPresent(path.join(context.root, relative));
    const parsed = before === undefined ? undefined : parseObject(before);

    if (
      entry.name !== appName &&
      entry.path !== NEW_PACKAGE_ROOT &&
      before !== undefined &&
      parsed !== undefined &&
      parsed.generatedSettings !== true &&
      hasGeneratedSettings(context.root, entry)
    ) {
      const after = withProperty(before, 'generatedSettings', 'true');

      if (writeIfChanged(context, {after, before, relative})) {
        context.lines.push(reportLine('generated-settings', entry.name));
      }
    }
  }
};

const updateWorkspace = (context: Context): string | undefined => {
  const before = readTextIfPresent(path.join(context.root, WORKSPACE_FILE));
  const edit =
    before === undefined ?
      ({changed: true, ok: true, text: NEW_WORKSPACE} as const)
    : editWorkspacePackages(before);

  if (!edit.ok) return edit.message;

  if (
    writeIfChanged(context, {
      after: edit.text,
      before,
      relative: WORKSPACE_FILE,
    })
  ) {
    context.lines.push(reportLine('workspace', WORKSPACE_FILE));
  }

  return undefined;
};

const reportMatchedFolders = (context: Context): void => {
  for (const {folder, lifecycle} of matchedFolders(context.root)) {
    context.lines.push(reportLine('newly-matched', folder));

    if (lifecycle.length > 0) {
      context.lines.push(
        reportLine('lifecycle-scripts', `${folder}: ${lifecycle.join(', ')}`)
      );
    }
  }
};

const ensureKeepFile = (context: Context): void => {
  const file = path.join(context.root, KEEP_FILE);

  context.staged.add(KEEP_FILE);
  if (existsSync(file)) return;
  mkdirSync(path.dirname(file), {recursive: true});
  writeFileSync(file, '');
  context.lines.push(reportLine('keep-file', KEEP_FILE));
};

const stage = (context: Context): boolean => {
  const named = [...context.staged].filter((relative) =>
    existsSync(path.join(context.root, relative))
  );

  try {
    execGaiaGit(
      ['add', '--', ...named.map((relative) => `:(literal)${relative}`)],
      context.root
    );

    return true;
  } catch {
    return false;
  }
};

const preconditionStop = (root: string): Outcome | undefined => {
  const legacy = path.join(root, LEGACY_PACKAGE_ROOT);
  const home = path.join(root, NEW_PACKAGE_ROOT);

  if (isSymlink(legacy) || isSymlink(path.join(root, APPS_DIRECTORY))) {
    return stop(
      'symlink',
      'replace the symlink at the old app root or at the apps directory with a real directory, then re-run the note'
    );
  }
  const legacyHolds = isDirectory(legacy);
  const homeHolds = existsSync(home);

  if (legacyHolds && homeHolds) {
    return stop(
      'both-trees-present',
      'move or remove one of the two app directories so only one holds the app, then re-run the note'
    );
  }

  if (!legacyHolds && !homeHolds) {
    return stop(
      'app-missing',
      'restore the app directory at its old or new path, then re-run the note'
    );
  }

  return undefined;
};

export const runMove = (workingDirectory: string): Outcome => {
  const root = topLevelOf(workingDirectory);

  if (root === undefined) {
    return stop(
      'not-root-launch',
      'start the session at the repository root and re-run the note'
    );
  }
  const refusal = preconditionStop(root);

  if (refusal !== undefined) return refusal;
  const context: Context = {lines: [], root, staged: new Set()};

  if (isDirectory(path.join(root, LEGACY_PACKAGE_ROOT))) {
    recordIgnored(root);
    mkdirSync(path.join(root, APPS_DIRECTORY), {recursive: true});
    execGaiaGit(['mv', LEGACY_PACKAGE_ROOT, NEW_PACKAGE_ROOT], root);
    context.lines.push(
      reportLine('moved', `${LEGACY_PACKAGE_ROOT} to ${NEW_PACKAGE_ROOT}`)
    );
  }

  const memberName = updateRegistry(context);

  if (memberName === undefined) {
    return stop(
      'registry-path',
      'correct .gaia/packages.json so exactly one member sits at the app path, then re-run the note'
    );
  }
  updateDescriptor(context, memberName);
  updatePackageName(context);
  markGeneratedSettings(context, memberName);
  const workspaceProblem = updateWorkspace(context);

  if (workspaceProblem !== undefined) {
    return stop(
      'workspace-unsupported',
      `${workspaceProblem}; convert the packages key to a block list, then re-run the note`
    );
  }
  ensureKeepFile(context);
  reportMatchedFolders(context);

  if (!stage(context)) {
    return stop(
      'stage-failed',
      'resolve the git error shown by git add on the named paths, then re-run the note'
    );
  }

  return done(context.lines);
};
