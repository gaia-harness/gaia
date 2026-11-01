import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdtempSync, realpathSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {execGaiaGit} from './git-env.js';
import {writeMemberRegistry} from './package-fixture.js';
import type {FixtureMember} from './package-fixture.js';
import {resolveWebTarget} from './package-target.js';

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

  test('several web members with no flag fail naming every candidate', () => {
    register([
      {name: 'storefront', path: 'apps/storefront'},
      {name: 'admin', path: 'apps/admin'},
    ]);

    const target = resolveWebTarget(root);

    expect(target.ok).toBe(false);
    expect(target.ok ? '' : target.message).toContain('storefront');
    expect(target.ok ? '' : target.message).toContain('admin');
  });

  test('no web member fails naming the registry and the stack field', () => {
    register([{name: 'lib', path: 'packages/lib', web: false}]);

    const target = resolveWebTarget(root);

    expect(target.ok).toBe(false);
    expect(target.ok ? '' : target.message).toContain('.gaia/packages.json');
    expect(target.ok ? '' : target.message).toContain('stack');
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

  test.each(['lib', 'ghost'])(
    'a flag naming %s fails and names the web member',
    (name) => {
      register([
        {name: 'lib', path: 'packages/lib', web: false},
        {name: 'storefront', path: 'apps/storefront'},
      ]);

      const target = resolveWebTarget(root, name);

      expect(target.ok).toBe(false);
      expect(target.ok ? '' : target.message).toContain('storefront');
    }
  );
});
