/**
 * The service-layer half of `gaia init rename`: moves the template's sample
 * domain layer, `app/services/gaia/`, to `app/services/<kebab>/` and rewrites
 * every module specifier that names it.
 *
 * The source folder is `gaia`, or the slug an earlier `rename` recorded in
 * `.gaia/init-state.json`, so re-running `rename` with a new slug (the way
 * `/gaia-init` documents changing it) moves the layer again rather than
 * leaving it under the first slug.
 */
import {existsSync, readFileSync, renameSync, statSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {escapeRegExp} from '../util/escape-regexp.js';
import {collectTreeFiles} from '../util/tree-walk.js';

const TEMPLATE_LAYER = 'gaia';

/**
 * The package's source roots. Walking the package root would descend
 * `node_modules`, and the walk excludes no directory by design.
 */
const SOURCE_ROOTS = ['app', 'test', '.storybook', '.playwright'] as const;

const SOURCE_EXTENSIONS: ReadonlySet<string> = new Set([
  '.cjs',
  '.cts',
  '.js',
  '.jsx',
  '.mdx',
  '.mjs',
  '.mts',
  '.ts',
  '.tsx',
]);

/** A plan `applyServiceLayerMove` can carry out. */
export type RunnableServiceLayerPlan =
  {from: string; kind: 'move'; to: string} | {kind: 'none'};

export type ServiceLayerPlan =
  RunnableServiceLayerPlan | {kind: 'conflict'; message: string};

const servicesDir = (packageDir: string): string =>
  path.join(packageDir, 'app', 'services');

const isDirectory = (target: string): boolean =>
  existsSync(target) && statSync(target).isDirectory();

/**
 * What the move would do, decided before any write so a refusal leaves the
 * tree as it was.
 *
 * Nothing to do when the slug is the source name or no source folder exists
 * (already moved, or deleted by the user). A target folder that already
 * exists beside the source is refused rather than merged: merging two
 * domain layers is a design decision, not a rename.
 */
export const planServiceLayerMove = (
  packageDir: string,
  kebab: string,
  previousKebab: string | undefined
): ServiceLayerPlan => {
  const candidates = [previousKebab, TEMPLATE_LAYER].filter(
    (name): name is string => name !== undefined && name !== kebab
  );
  const from = candidates.find((name) =>
    isDirectory(path.join(servicesDir(packageDir), name))
  );

  if (from === undefined) return {kind: 'none'};

  if (existsSync(path.join(servicesDir(packageDir), kebab))) {
    return {
      kind: 'conflict',
      message: `app/services/${kebab}/ already exists beside app/services/${from}/; merge or remove one, then re-run`,
    };
  }

  return {from, kind: 'move', to: kebab};
};

/**
 * `source` with every quoted specifier segment `services/<from>` rewritten to
 * `services/<to>`: the `~/services/<from>/...` alias, a relative
 * `../services/<from>`, and a repo path such as `app/services/<from>/`. The
 * segment must end at `/` or the closing quote, so `services/<from>-x` is
 * left alone.
 */
export const rewriteServiceSpecifiers = (
  source: string,
  from: string,
  to: string
): string =>
  source.replaceAll(
    new RegExp(
      String.raw`(['"\x60])((?:(?!\1)[^\n\\])*?\bservices/)${escapeRegExp(from)}(?=/|\1)`,
      'gu'
    ),
    (_match: string, quote: string, prefix: string) => `${quote}${prefix}${to}`
  );

const rewriteImports = (packageDir: string, from: string, to: string): void => {
  const files = SOURCE_ROOTS.map((root) => path.join(packageDir, root))
    .filter((rootDir) => isDirectory(rootDir))
    .flatMap((rootDir) =>
      collectTreeFiles(rootDir, SOURCE_EXTENSIONS).map((relative) =>
        path.join(rootDir, relative)
      )
    );

  for (const file of files) {
    const original = readFileSync(file, 'utf8');
    const next = rewriteServiceSpecifiers(original, from, to);

    if (next !== original) atomicWriteFileSync(file, next);
  }
};

/**
 * Carries out a plan; `none` writes nothing.
 *
 * Specifiers are rewritten before the folder moves. A run that dies between
 * the two still has its source folder, so the replay finds it, rewrites
 * nothing new and moves it; the other order would leave a moved folder and
 * stale imports that no replay could attribute to a source any more.
 */
export const applyServiceLayerMove = (
  packageDir: string,
  plan: RunnableServiceLayerPlan
): void => {
  if (plan.kind === 'none') return;
  rewriteImports(packageDir, plan.from, plan.to);
  renameSync(
    path.join(servicesDir(packageDir), plan.from),
    path.join(servicesDir(packageDir), plan.to)
  );
};
