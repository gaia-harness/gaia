/**
 * Test fixtures that pin a temp tree to a literal registry and descriptor, by
 * default the transitional layout (the app at the repo root). The descriptor
 * is the committed `frontend/gaia.package.json`, the one copy of the default
 * globs.
 */
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import type {PackageDescriptor} from './packages.js';
import {resolveRepoRootFromImportMeta} from './repo-root-fixture.js';

/** The committed frontend descriptor, parsed. */
export const committedFrontendDescriptor = (): PackageDescriptor =>
  JSON.parse(
    readFileSync(
      path.join(
        resolveRepoRootFromImportMeta(import.meta.url),
        'frontend',
        'gaia.package.json'
      ),
      'utf8'
    )
  ) as PackageDescriptor;

/**
 * Write the committed descriptor at `frontend/`, with no registry: the tree an
 * adopter has, where the built-in registry names the frontend package.
 */
export const writeBuiltinDescriptor = (root: string): void => {
  mkdirSync(path.join(root, 'frontend'), {recursive: true});
  writeFileSync(
    path.join(root, 'frontend', 'gaia.package.json'),
    JSON.stringify(committedFrontendDescriptor())
  );
};

/** Register the frontend package at `packagePath` with the committed descriptor. */
export const writeFrontendRegistry = (
  root: string,
  packagePath = '.'
): void => {
  mkdirSync(path.join(root, '.gaia'), {recursive: true});
  writeFileSync(
    path.join(root, '.gaia', 'packages.json'),
    JSON.stringify([{name: 'frontend', path: packagePath}])
  );
  const descriptorDir =
    packagePath === '.' ? root : path.join(root, packagePath);

  mkdirSync(descriptorDir, {recursive: true});
  writeFileSync(
    path.join(descriptorDir, 'gaia.package.json'),
    JSON.stringify(committedFrontendDescriptor())
  );
};
