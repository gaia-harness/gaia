import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {writeMemberRegistry} from '../util/package-fixture.js';
import {readClassifyPaths} from './classify-paths.js';

describe('readClassifyPaths', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-classify-paths-'));
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
  });

  test('classifies against a web member named storefront', () => {
    writeMemberRegistry(root, [
      {name: 'lib', path: 'packages/lib', web: false},
      {name: 'storefront', path: 'apps/storefront'},
    ]);

    const {sourcePaths} = readClassifyPaths(root);

    expect(sourcePaths.length).toBeGreaterThan(0);
    expect(
      sourcePaths.every((entry) => entry.startsWith('apps/storefront/'))
    ).toBe(true);
  });

  test('classifies against every web member', () => {
    writeMemberRegistry(root, [
      {name: 'storefront', path: 'apps/storefront'},
      {name: 'admin', path: 'apps/admin'},
    ]);

    const {sourcePaths} = readClassifyPaths(root);

    expect(
      sourcePaths.some((entry) => entry.startsWith('apps/storefront/'))
    ).toBe(true);
    expect(sourcePaths.some((entry) => entry.startsWith('apps/admin/'))).toBe(
      true
    );
  });

  test('throws naming the stack field when no member is web', () => {
    writeMemberRegistry(root, [
      {name: 'lib', path: 'packages/lib', web: false},
    ]);

    expect(() => readClassifyPaths(root)).toThrow(/"stack": "web"/u);
  });
});
