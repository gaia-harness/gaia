import picomatch from 'picomatch';
import type {Node} from 'typescript';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {execGaiaGitRaw} from '../util/git-env.js';
import type {Ts} from './repairs/index.js';

const MAIN_FILE_NAMES = [
  'main.ts',
  'main.mts',
  'main.js',
  'main.mjs',
  'main.cjs',
  'main.cts',
];
const PREVIEW_FILE_NAMES = [
  'preview.ts',
  'preview.tsx',
  'preview.js',
  'preview.jsx',
  'preview.mts',
  'preview.mjs',
];

const SCRIPT_FILE = /\.[cm]?[jt]sx?$/u;

const FALLBACK_STORY_GLOB = 'app/**/*.stories.{ts,tsx}';

export type StoryInventory = {
  /** Set when the stories globs were not literal and the fallback was used. */
  fallbackReason: string | undefined;
  /** Package-relative, forward slashes. */
  storyFiles: string[];
};

/** Files the package owns: tracked plus untracked-not-ignored, as package-relative paths. */
export const listPackageFiles = (packageDir: string): string[] =>
  execGaiaGitRaw(
    [
      '-c',
      'core.quotepath=false',
      'ls-files',
      '-z',
      '--cached',
      '--others',
      '--exclude-standard',
      '--',
      '.',
    ],
    packageDir
  )
    .split('\0')
    .filter((entry) => entry.length > 0)
    .filter((entry) => existsSync(path.join(packageDir, entry)))
    .toSorted((left, right) => left.localeCompare(right));

const findExisting = (
  directory: string,
  names: readonly string[]
): string | undefined =>
  names
    .map((name) => path.join(directory, name))
    .find((candidate) => existsSync(candidate));

export const findMainPath = (packageDir: string): string | undefined =>
  findExisting(path.join(packageDir, '.storybook'), MAIN_FILE_NAMES);

export const findPreviewPath = (packageDir: string): string | undefined =>
  findExisting(path.join(packageDir, '.storybook'), PREVIEW_FILE_NAMES);

type LiteralGlobs = {globs: string[]; ok: true} | {ok: false; reason: string};

const readLiteralGlobs = (ts: Ts, mainPath: string): LiteralGlobs => {
  const sourceFile = ts.createSourceFile(
    mainPath,
    readFileSync(mainPath, 'utf8'),
    ts.ScriptTarget.Latest,
    true
  );
  let found: LiteralGlobs = {ok: false, reason: 'main has no stories array'};

  const visit = (node: Node): void => {
    if (
      ts.isPropertyAssignment(node) &&
      ts.isIdentifier(node.name) &&
      node.name.text === 'stories' &&
      ts.isArrayLiteralExpression(node.initializer)
    ) {
      const globs: string[] = [];
      const literal = node.initializer.elements.every((element) => {
        if (
          ts.isStringLiteral(element) ||
          ts.isNoSubstitutionTemplateLiteral(element)
        ) {
          globs.push(element.text);

          return true;
        }

        return false;
      });

      found =
        literal ?
          {globs, ok: true}
        : {ok: false, reason: 'the stories globs are not all string literals'};

      return;
    }
    ts.forEachChild(node, visit);
  };

  visit(sourceFile);

  return found;
};

/** Config-relative globs become package-relative ones. */
const toPackageGlob = (glob: string): string => {
  const negated = glob.startsWith('!');
  const body = negated ? glob.slice(1) : glob;
  const resolved = path.posix.normalize(path.posix.join('.storybook', body));

  return negated ? `!${resolved}` : resolved;
};

/**
 * Every story file main's `stories` globs match, read statically. A glob list
 * that is not literal cannot be evaluated without running the config, so the
 * default app glob stands in and the report says so.
 */
export const inventoryStoryFiles = (
  ts: Ts,
  packageDir: string
): StoryInventory => {
  const mainPath = findMainPath(packageDir);
  const literal: LiteralGlobs =
    mainPath === undefined ?
      {ok: false, reason: 'no .storybook/main file was found'}
    : readLiteralGlobs(ts, mainPath);
  const files = listPackageFiles(packageDir);

  const globs = literal.ok ? literal.globs.map(toPackageGlob) : [];
  const positive =
    literal.ok ?
      globs.filter((glob) => !glob.startsWith('!'))
    : [FALLBACK_STORY_GLOB];
  const negative = globs
    .filter((glob) => glob.startsWith('!'))
    .map((glob) => glob.slice(1));
  const matchPositive = picomatch(positive);
  const matchNegative = negative.length > 0 ? picomatch(negative) : undefined;

  return {
    fallbackReason: literal.ok ? undefined : literal.reason,
    // Docs pages (.mdx) match the same globs but are not story modules.
    storyFiles: files.filter(
      (file) =>
        SCRIPT_FILE.test(file) &&
        matchPositive(file) &&
        !(matchNegative?.(file) ?? false)
    ),
  };
};
