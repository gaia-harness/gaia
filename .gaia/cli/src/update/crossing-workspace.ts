/**
 * The workspace-file half of the crossing move: a by-line edit of the
 * `packages` list in `pnpm-workspace.yaml`, and the listing of folders the new
 * globs match. The edit never parses the whole file, so every line outside the
 * list stays byte-identical and comments survive.
 */
import {readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {
  APPS_DIRECTORY,
  compareCodeUnits,
  isBlankOrComment,
  LEGACY_PACKAGE_ROOT,
  NEW_PACKAGE_ROOT,
  PACKAGES_DIRECTORY,
  parseListItem,
} from './crossing-shared.js';
import type {ListItem} from './crossing-shared.js';

export type MatchedFolder = {folder: string; lifecycle: string[]};

export type WorkspaceEdit =
  {changed: boolean; ok: true; text: string} | {message: string; ok: false};

const APPS_GLOB = `${APPS_DIRECTORY}/*`;
const PACKAGES_GLOB = `${PACKAGES_DIRECTORY}/*`;
const LIFECYCLE_SCRIPTS = [
  'preinstall',
  'install',
  'postinstall',
  'prepublish',
  'preprepare',
  'prepare',
  'postprepare',
];

/** A list value without quotes, a leading `./` or trailing slashes. */
const normalize = (value: string): string => {
  let normalized = value.trim().replace(/^\.\//u, '');

  while (normalized.endsWith('/')) normalized = normalized.slice(0, -1);

  return normalized;
};

const isPackagesKey = (line: string): boolean =>
  line.startsWith('packages:') &&
  isBlankOrComment(line.slice('packages:'.length));

/** Replaces the app entry with the apps glob and appends the packages glob. */
export const editWorkspacePackages = (text: string): WorkspaceEdit => {
  const lines = text.split('\n');
  const keyIndex = lines.findIndex((line) => isPackagesKey(line.trimEnd()));

  if (keyIndex === -1) {
    return {
      message: 'pnpm-workspace.yaml has no block-style packages list',
      ok: false,
    };
  }

  const items: {index: number; item: ListItem}[] = [];

  for (let index = keyIndex + 1; index < lines.length; index += 1) {
    const line = lines[index] ?? '';
    const item = parseListItem(line.replace(/\r$/u, ''));

    if (item !== undefined) {
      items.push({index, item});
    } else if (!isBlankOrComment(line)) {
      break;
    }
  }

  const last = items.at(-1);

  if (last === undefined) {
    return {message: 'the packages list has no entries', ok: false};
  }

  const values = items.map(({item}) => normalize(item.value));
  const hasApps = values.includes(APPS_GLOB);
  const hasPackages = values.includes(PACKAGES_GLOB);
  const dropped = new Set<number>();
  let appsAdded = hasApps;

  items.forEach(({index, item}, position) => {
    if (values[position] !== LEGACY_PACKAGE_ROOT) return;

    if (appsAdded) {
      dropped.add(index);

      return;
    }
    const carriageReturn = (lines[index] ?? '').endsWith('\r') ? '\r' : '';

    lines[index] =
      `${item.head}${item.quote}${APPS_GLOB}${item.quote}${item.rest}${carriageReturn}`;
    appsAdded = true;
  });

  const anchor = items.findLast(({index}) => !dropped.has(index)) ?? last;
  const appended = [
    ...(appsAdded ? [] : [APPS_GLOB]),
    ...(hasPackages ? [] : [PACKAGES_GLOB]),
  ];

  if (appended.length > 0) {
    const carriageReturn =
      (lines[anchor.index] ?? '').endsWith('\r') ? '\r' : '';
    const addedLines = appended
      .map((glob) => `${anchor.item.head}${glob}${carriageReturn}`)
      .join('\n');

    lines[anchor.index] = `${lines[anchor.index] ?? ''}\n${addedLines}`;
  }

  const edited = lines.filter((_line, index) => !dropped.has(index)).join('\n');

  return {changed: edited !== text, ok: true, text: edited};
};

const subdirectories = (directory: string): string[] => {
  try {
    return readdirSync(directory, {withFileTypes: true})
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .toSorted(compareCodeUnits);
  } catch {
    return [];
  }
};

const lifecycleScriptsOf = (packageJsonPath: string): string[] | undefined => {
  try {
    const parsed = JSON.parse(readFileSync(packageJsonPath, 'utf8')) as {
      scripts?: Record<string, unknown>;
    };
    const scripts = Object.keys(parsed.scripts ?? {});

    return LIFECYCLE_SCRIPTS.filter((name) => scripts.includes(name));
  } catch {
    return undefined;
  }
};

/** Package folders under the two globs, the app's own home excluded. */
export const matchedFolders = (root: string): MatchedFolder[] => {
  const found: MatchedFolder[] = [];

  for (const parent of [APPS_DIRECTORY, PACKAGES_DIRECTORY]) {
    for (const name of subdirectories(path.join(root, parent))) {
      const folder = `${parent}/${name}`;
      const lifecycle =
        folder === NEW_PACKAGE_ROOT ? undefined : (
          lifecycleScriptsOf(path.join(root, folder, 'package.json'))
        );

      if (lifecycle !== undefined) found.push({folder, lifecycle});
    }
  }

  return found;
};
