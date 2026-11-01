import {load as parseYaml} from 'js-yaml';
import picomatch from 'picomatch';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {isRegistrablePath, loadPackages} from '../../util/packages.js';
import type {RuleContext} from '../context.js';
import {compareBytes} from '../markdown.js';
import type {RawFinding, RuleDefinition} from '../types.js';

const WORKSPACE_FILE = 'pnpm-workspace.yaml';
const PACKAGE_FILE = 'package.json';
const GUIDE = 'wiki/concepts/Package Descriptor.md "Adding an app or package"';

/** The `packages` globs of the workspace file; empty when it is absent or unreadable. */
const workspaceGlobs = (root: string): string[] => {
  let parsed: unknown;

  try {
    parsed = parseYaml(readFileSync(path.join(root, WORKSPACE_FILE), 'utf8'));
  } catch {
    return [];
  }

  const packages = (parsed as null | {packages?: unknown})?.packages;

  return Array.isArray(packages) ?
      packages.filter((entry): entry is string => typeof entry === 'string')
    : [];
};

/** Every directory that holds a package.json and matches the workspace globs. */
const memberFolders = (context: RuleContext): string[] => {
  const globs = workspaceGlobs(context.rootDirectory);
  const include = globs.filter((glob) => !glob.startsWith('!'));
  const exclude = globs
    .filter((glob) => glob.startsWith('!'))
    .map((glob) => glob.slice(1));

  if (include.length === 0) return [];

  const matches = picomatch(include, {dot: true, ignore: exclude});
  const folders = new Set<string>();

  for (const tracked of context.allTrackedPaths) {
    const folder = path.posix.dirname(tracked);

    if (
      tracked.endsWith(`/${PACKAGE_FILE}`) &&
      !folder.split('/').includes('node_modules') &&
      matches(folder)
    ) {
      folders.add(folder);
    }
  }

  const sorted = [...folders];

  return sorted.toSorted(compareBytes);
};

/** The workspace members `.gaia/packages.json` does not list. A registry that cannot load is another check's finding. */
const unregisteredFolders = (context: RuleContext): string[] => {
  const loaded = loadPackages(context.rootDirectory);

  if (!loaded.ok) return [];

  const registered = new Set(loaded.packages.map((entry) => entry.path));

  return memberFolders(context).filter((folder) => !registered.has(folder));
};

const suggestedPath = (folder: string): string =>
  folder
    .toLowerCase()
    .replaceAll(/[^a-z0-9._/-]/g, '-')
    .replace(/^[^a-z0-9]+/, '');

const unregisteredCheck = (context: RuleContext): readonly RawFinding[] =>
  unregisteredFolders(context)
    .filter((folder) => isRegistrablePath(folder))
    .map((folder) => ({
      file: `${folder}/${PACKAGE_FILE}`,
      line: 1,
      message: `Workspace member ${folder} is not in .gaia/packages.json, so the harness cannot see it.`,
      remediation: `Add an entry for ${folder} to .gaia/packages.json and give it a ${folder}/gaia.package.json descriptor. See ${GUIDE}.`,
    }));

const unregistrableCheck = (context: RuleContext): readonly RawFinding[] =>
  unregisteredFolders(context)
    .filter((folder) => !isRegistrablePath(folder))
    .map((folder) => ({
      file: `${folder}/${PACKAGE_FILE}`,
      line: 1,
      message: `Workspace member ${folder} cannot be listed in .gaia/packages.json: the registry refuses its path.`,
      remediation: `Rename the folder to a lowercase path with no leading dot, such as ${suggestedPath(folder)}, then register it in .gaia/packages.json with a gaia.package.json descriptor. See ${GUIDE}.`,
    }));

export const WORKSPACE_RULES: readonly RuleDefinition[] = [
  {
    appliesTo: ['all'],
    category: 'settings',
    check: unregisteredCheck,
    detection:
      'A pnpm workspace member with a package.json is not listed in .gaia/packages.json, so the harness cannot see it.',
    ruleId: 'settings.workspace-member-unregistered',
    severity: 'warning',
  },
  {
    appliesTo: ['all'],
    category: 'settings',
    check: unregistrableCheck,
    detection:
      'A pnpm workspace member has a path the package registry refuses (uppercase, a leading dot or another disallowed character), so it cannot be listed as it is.',
    ruleId: 'settings.workspace-member-unregistrable',
    severity: 'warning',
  },
];
