/**
 * `gaia update lockfile-command --root <dir> [--ref <git ref>] [--json]`
 * handler.
 *
 * Prints which pnpm command the lockfile needs after an update changed the
 * tree against `--ref` (default HEAD): `dedupe` when a resolution setting
 * moved, `install` when only dependency or packageManager entries moved,
 * otherwise `none`. Resolution settings win because `pnpm install` keeps
 * already-resolved versions and only `pnpm dedupe` re-resolves under a new
 * override, allowBuilds or peer setting.
 *
 * It is READ-ONLY. The ref's copy of each file comes from `git show` run
 * through `execFileSync` with an argv array, so a ref or path is never
 * interpreted by a shell.
 */
import {load as parseYaml} from 'js-yaml';
import {execFileSync} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {parseValueFlags} from '../util/parse-value-flags.js';
import type {ValueFlagMap} from '../util/parse-value-flags.js';
import {asRecord, deepEqual} from './field-verdict.js';

const HELP_TEXT = `Usage: gaia update lockfile-command --root <dir> [--ref <git ref>] [--json]

  Prints dedupe, install or none: the pnpm command the lockfile needs after the
  tree under <dir> changed against <ref> (default HEAD). Compares the root
  pnpm-workspace.yaml and every package.json (the root plus each package in
  .gaia/packages.json, default frontend).

  Exit codes:
    0  success
    1  user-correctable error (missing flag, unreadable ref, malformed file)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const RESOLUTION_SETTINGS: readonly string[] = [
  'overrides',
  'allowBuilds',
  'resolutionMode',
  'dedupePeerDependents',
  'dedupePeers',
  'autoInstallPeers',
  'strictPeerDependencies',
  'resolvePeersFromWorkspaceRoot',
  'peerDependencyRules',
];

const toKebabCase = (name: string): string =>
  name.replaceAll(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);

const RESOLUTION_KEYS: readonly string[] = RESOLUTION_SETTINGS.flatMap(
  (name) => [name, toKebabCase(name)]
);

const INSTALL_KEYS: readonly string[] = [
  'dependencies',
  'devDependencies',
  'optionalDependencies',
  'peerDependencies',
  'packageManager',
];

type Command = 'dedupe' | 'install' | 'none';

type Flags = {json: boolean; ref: string; root: string};

type ParsedFlagsResult =
  {flags: Flags; ok: true} | {message: string; ok: false};

const VALUE_FLAGS: ValueFlagMap<'ref' | 'root'> = {
  '--ref': 'ref',
  '--root': 'root',
};

const parseFlags = (argv: readonly string[]): ParsedFlagsResult => {
  const parsed = parseValueFlags(argv, VALUE_FLAGS);

  if (!parsed.ok) return parsed;

  const {
    collected: {ref, root},
    json,
  } = parsed.state;

  if (root === undefined) return {message: '--root is required', ok: false};

  return {flags: {json, ref: ref ?? 'HEAD', root}, ok: true};
};

class LockfileCommandError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

const gitShow = (root: string, ref: string, relativePath: string): string => {
  try {
    return execFileSync('git', ['-C', root, 'show', `${ref}:${relativePath}`], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch {
    // The path is absent at the ref; an unreadable ref is caught before this.
    return '';
  }
};

const assertReadableRef = (root: string, ref: string): void => {
  try {
    execFileSync(
      'git',
      ['-C', root, 'rev-parse', '--verify', '--quiet', `${ref}^{commit}`],
      {stdio: ['ignore', 'ignore', 'ignore']}
    );
  } catch {
    throw new LockfileCommandError(
      'ref_unreadable',
      `cannot read git ref ${ref} in ${root}`
    );
  }
};

const parseText = (
  text: string,
  format: 'json' | 'yaml',
  label: string
): Record<string, unknown> => {
  if (text.trim() === '') return {};

  try {
    return asRecord(format === 'json' ? JSON.parse(text) : parseYaml(text));
  } catch (error) {
    throw new LockfileCommandError(
      'parse_failed',
      `${label} is not valid ${format.toUpperCase()}: ${
        error instanceof Error ? error.message : String(error)
      }`
    );
  }
};

const readWorkingTree = (
  root: string,
  relativePath: string
): Record<string, unknown> => {
  const absolute = path.join(root, relativePath);

  if (!existsSync(absolute)) return {};

  return parseText(
    readFileSync(absolute, 'utf8'),
    relativePath.endsWith('.json') ? 'json' : 'yaml',
    relativePath
  );
};

const PLAIN_DIRECTORY =
  /^(?:\.|[a-z0-9][a-z0-9._-]*(?:\/[a-z0-9][a-z0-9._-]*)*)$/;

// Mirrors how the update flow builds its package list: an absent or unreadable
// registry means the stock frontend package, and a path that is not a plain
// relative directory is dropped so a hand-edited registry cannot steer the
// comparison outside the tree.
const packageDirectories = (root: string): string[] => {
  let registered: string[] = ['frontend'];
  const registryPath = path.join(root, '.gaia', 'packages.json');

  if (existsSync(registryPath)) {
    try {
      const parsed: unknown = JSON.parse(readFileSync(registryPath, 'utf8'));

      if (Array.isArray(parsed)) {
        registered = parsed.flatMap((entry: unknown) => {
          const entryPath = asRecord(entry).path;

          return typeof entryPath === 'string' ? [entryPath] : [];
        });
      }
    } catch {
      registered = ['frontend'];
    }
  }

  return [
    ...new Set(
      ['.', ...registered].filter(
        (directory) =>
          PLAIN_DIRECTORY.test(directory) && !directory.includes('..')
      )
    ),
  ];
};

const changed = (
  before: Record<string, unknown>,
  after: Record<string, unknown>,
  keys: readonly string[]
): boolean => keys.some((key) => !deepEqual(before[key], after[key]));

const resolutionChanged = (
  before: Record<string, unknown>,
  after: Record<string, unknown>
): boolean =>
  changed(before, after, RESOLUTION_KEYS) ||
  changed(asRecord(before.pnpm), asRecord(after.pnpm), RESOLUTION_KEYS);

export const lockfileCommand = (root: string, ref: string): Command => {
  assertReadableRef(root, ref);

  const compare = (relativePath: string) => {
    const format = relativePath.endsWith('.json') ? 'json' : 'yaml';

    return {
      after: readWorkingTree(root, relativePath),
      before: parseText(
        gitShow(root, ref, relativePath),
        format,
        `${relativePath} at ${ref}`
      ),
    };
  };

  const workspace = compare('pnpm-workspace.yaml');
  if (resolutionChanged(workspace.before, workspace.after)) return 'dedupe';

  let command: Command = 'none';

  for (const directory of packageDirectories(root)) {
    const {after, before} = compare(
      directory === '.' ? 'package.json' : `${directory}/package.json`
    );

    if (resolutionChanged(before, after)) return 'dedupe';
    if (changed(before, after, INSTALL_KEYS)) command = 'install';
  }

  return command;
};

export const run = (argv: readonly string[]): number => {
  const [firstArgument] = argv;

  if (firstArgument !== undefined && HELP_TOKENS.has(firstArgument)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'update lockfile-command',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let command: Command;

  try {
    command = lockfileCommand(
      path.resolve(parsed.flags.root),
      parsed.flags.ref
    );
  } catch (error) {
    if (!(error instanceof LockfileCommandError)) throw error;

    structuredError({
      code: error.code,
      message: error.message,
      subcommand: 'update lockfile-command',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  process.stdout.write(
    parsed.flags.json ? `${JSON.stringify({command})}\n` : `${command}\n`
  );

  return EXIT_CODES.OK;
};
