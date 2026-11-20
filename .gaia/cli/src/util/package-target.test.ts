import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdtempSync, realpathSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {execGaiaGit} from './git-env.js';
import {writeMemberRegistry} from './package-fixture.js';
import type {FixtureMember} from './package-fixture.js';
import {resolveWebTarget} from './package-target.js';

const STOREFRONT: FixtureMember = {name: 'storefront', path: 'apps/storefront'};
const ADMIN: FixtureMember = {name: 'admin', path: 'apps/admin'};
const LIB: FixtureMember = {name: 'lib', path: 'packages/lib', web: false};

describe('resolveWebTarget', () => {
  let root: string;

  beforeEach(() => {
    root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-web-target-')));
    execGaiaGit(['init', '-q', '-b', 'main'], root);
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
  });

  const register = (members: readonly FixtureMember[]): void =>
    writeMemberRegistry(root, members);

  test('one web member under another name resolves with no flag', () => {
    register([{name: 'storefront', path: 'apps/storefront'}]);

    expect(resolveWebTarget(root)).toMatchObject({
      ok: true,
      packagePath: 'apps/storefront',
    });
  });

  test('one web member resolves from a working directory inside a non-web member', () => {
    register([
      {name: 'lib', path: 'packages/lib', web: false},
      {name: 'storefront', path: 'apps/storefront'},
    ]);

    expect(resolveWebTarget(path.join(root, 'packages/lib'))).toMatchObject({
      ok: true,
      packagePath: 'apps/storefront',
    });
  });

  test('a flag naming a web member resolves it among several', () => {
    register([
      {name: 'storefront', path: 'apps/storefront'},
      {name: 'admin', path: 'apps/admin'},
    ]);

    expect(resolveWebTarget(root, 'admin')).toMatchObject({
      ok: true,
      packagePath: 'apps/admin',
    });
  });

  test.each(
    [
      {
        contains: ['storefront', 'admin'],
        excludes: [],
        members: [STOREFRONT, ADMIN],
        name: 'several web members with no flag fail naming every candidate',
        packageName: undefined,
        takesPackage: undefined,
      },
      {
        contains: [],
        excludes: ['--package'],
        members: [STOREFRONT, ADMIN],
        name: 'the several-members refusal names --package only for a caller that takes it (caller without it)',
        packageName: undefined,
        takesPackage: undefined,
      },
      {
        contains: ['--package'],
        excludes: [],
        members: [STOREFRONT, ADMIN],
        name: 'the several-members refusal names --package only for a caller that takes it (caller with it)',
        packageName: undefined,
        takesPackage: true,
      },
      {
        contains: ['.gaia/packages.json', 'stack'],
        excludes: [],
        members: [LIB],
        name: 'no web member fails naming the registry and the stack field',
        packageName: undefined,
        takesPackage: undefined,
      },
      ...['lib', 'ghost'].map((packageName) => ({
        contains: ['storefront'],
        excludes: [],
        members: [LIB, STOREFRONT],
        name: `a flag naming ${packageName} fails and names the web member`,
        packageName,
        takesPackage: undefined,
      })),
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {contains, excludes, members, packageName, takesPackage}) => {
    register(members);

    const target = resolveWebTarget(root, packageName, takesPackage);
    const message = target.ok ? '' : target.message;

    expect(target.ok).toBe(false);
    for (const text of contains) expect(message).toContain(text);
    for (const text of excludes) expect(message).not.toContain(text);
  });
});
