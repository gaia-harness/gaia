import semver from 'semver';
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  hasTanstackQuery,
  TANSTACK_QUERY_PACKAGE,
  TANSTACK_QUERY_VERSION,
} from './data-layer.js';

describe('hasTanstackQuery', () => {
  let packageDir: string;

  beforeEach(() => {
    packageDir = mkdtempSync(path.join(tmpdir(), 'gaia-data-layer-'));
  });

  afterEach(() => {
    rmSync(packageDir, {force: true, recursive: true});
  });

  const writePackageJson = (contents: unknown): void => {
    writeFileSync(
      path.join(packageDir, 'package.json'),
      JSON.stringify(contents)
    );
  };

  describe('hasTanstackQuery reads package.json dependencies', () => {
    test.each([
      {
        expected: true,
        manifests: [
          {
            dependencies: {[TANSTACK_QUERY_PACKAGE]: TANSTACK_QUERY_VERSION},
          },
        ],
        name: 'is true when the package is a dependency',
      },
      {
        expected: true,
        manifests: [
          {
            devDependencies: {[TANSTACK_QUERY_PACKAGE]: TANSTACK_QUERY_VERSION},
          },
        ],
        name: 'is true when the package is a devDependency',
      },
      {
        expected: false,
        manifests: [
          {
            dependencies: {react: '19.0.0'},
            devDependencies: {'@tanstack/query-core': TANSTACK_QUERY_VERSION},
          },
        ],
        name: 'is false when the package is absent',
      },
      {
        expected: false,
        manifests: [] as unknown[],
        name: 'is false when package.json is missing',
      },
    ])('$name', ({expected, manifests}) => {
      for (const manifest of manifests) {
        writePackageJson(manifest);
      }

      expect(hasTanstackQuery(packageDir)).toBe(expected);
    });
  });
});

describe('TANSTACK_QUERY_VERSION', () => {
  test('is an exact version', () => {
    expect(TANSTACK_QUERY_VERSION).toMatch(/^\d+\.\d+\.\d+$/u);
  });

  test('is at least the first release with queryClient.query', () => {
    expect(semver.gte(TANSTACK_QUERY_VERSION, '5.104.0')).toBe(true);
  });
});
