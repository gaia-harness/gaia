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

/** A registered member of a fixture tree; `web` false drops the stack field. */
export type FixtureMember = {
  name: string;
  path: string;
  web?: boolean;
};

/**
 * Register `members` and write each one's descriptor from the committed one,
 * renamed to the member and carrying the web stack unless `web` is false. The
 * tree the name-keyed behavior is proven on.
 */
export const writeMemberRegistry = (
  root: string,
  members: readonly FixtureMember[]
): void => {
  mkdirSync(path.join(root, '.gaia'), {recursive: true});
  writeFileSync(
    path.join(root, '.gaia', 'packages.json'),
    JSON.stringify(
      members.map((member) => ({name: member.name, path: member.path}))
    )
  );

  for (const member of members) {
    const descriptorDir =
      member.path === '.' ? root : path.join(root, member.path);
    const {stack, ...rest} = committedFrontendDescriptor();

    mkdirSync(descriptorDir, {recursive: true});
    writeFileSync(
      path.join(descriptorDir, 'gaia.package.json'),
      JSON.stringify({
        ...rest,
        name: member.name,
        ...(member.web === false ? {} : {stack}),
      })
    );
  }
};

/** Register the frontend package at `packagePath` with the committed descriptor. */
export const writeFrontendRegistry = (
  root: string,
  packagePath = '.',
  name = 'frontend'
): void => {
  writeMemberRegistry(root, [{name, path: packagePath}]);
};
