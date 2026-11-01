/**
 * Strategy: the TypeScript reader of the package registry is one of two
 * implementations of one contract, so most of what it must do is stated by the
 * shared corpus (`.gaia/tests/fixtures/gaia-packages/`), which the bash reader
 * is driven over too. This suite adds what the corpus cannot say: the
 * fail-closed result shapes, the built-in registry reading the committed
 * descriptor, hostile input, and a proof that the corpus check itself can fail.
 */
import {afterAll, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  CORPUS_DIRECTORY,
  corpusDisagreements,
  LEFTOVER_KEY_CASE,
  listCorpusCases,
  materializeCase,
  readExpected,
  retiredGlobsKey,
} from './gaia-packages-corpus-fixture.js';
import type {CorpusReader} from './gaia-packages-corpus-fixture.js';
import {writeBuiltinDescriptor} from './package-fixture.js';
import {
  BUILTIN_REGISTRY,
  globToRegExp,
  isRegistrablePath,
  joinGlob,
  loadPackages,
  repoRegExps,
  wantsGeneratedSettings,
  webMembers,
} from './packages.js';
import type {GlobKey, LoadedPackage} from './packages.js';
import {resolveRepoRootFromImportMeta} from './repo-root-fixture.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);
const SCRATCH = mkdtempSync(path.join(tmpdir(), 'gaia-packages-ts-'));

afterAll(() => {
  rmSync(SCRATCH, {force: true, recursive: true});
});

const READER: CorpusReader = {
  load: (root) => loadPackages(root),
  regExps: (packages, key) => repoRegExps(packages, key as GlobKey),
  settingsMembers: (packages) =>
    (packages as LoadedPackage[])
      .filter(wantsGeneratedSettings)
      .map((p) => p.name),
  webMembers: (packages) =>
    webMembers(packages as LoadedPackage[]).map((p) => p.name),
};

const rootFor = (caseName: string): string => {
  const root = path.join(SCRATCH, caseName);
  materializeCase(caseName, root);

  return root;
};

describe('corpus conformance', () => {
  const cases = listCorpusCases();

  test('the corpus is not empty (a mis-pathed corpus must not pass vacuously)', () => {
    expect(cases.length).toBeGreaterThanOrEqual(35);
  });

  test.each(cases)('%s', (caseName) => {
    expect(
      corpusDisagreements(readExpected(caseName), rootFor(caseName), READER)
    ).toEqual([]);
  });

  test('the check fails on a wrong expectation (guard can fail)', () => {
    const root = rootFor('path-frontend');
    const expected = readExpected('path-frontend');

    expect(corpusDisagreements(expected, root, READER)).toEqual([]);
    expect(corpusDisagreements({...expected, load: 3}, root, READER)).toEqual([
      'load: want 3, got 0',
    ]);
    expect(
      corpusDisagreements(
        {
          ...expected,
          globs: {tddUnitTests: {noMatch: ['frontend/app/x.test.ts']}},
        },
        root,
        READER
      )
    ).toEqual(['tddUnitTests: want NO match for [frontend/app/x.test.ts]']);
  });
});

describe('a retired globs key', () => {
  test('a descriptor still carrying it loads and the key is absent from the output', () => {
    const retiredKey = retiredGlobsKey();
    const result = loadPackages(rootFor(LEFTOVER_KEY_CASE));

    expect(retiredKey).not.toBe('');
    expect(result.ok).toBe(true);
    expect(JSON.stringify(result)).not.toContain(retiredKey);
  });
});

describe('fail-closed results', () => {
  test('a malformed registry is REGISTRY_MALFORMED and never ok', () => {
    const result = loadPackages(rootFor('registry-malformed-json'));

    expect(result.ok).toBe(false);
    expect(result).toMatchObject({code: 'REGISTRY_MALFORMED'});
    expect(!result.ok && result.message).toMatch(
      /^gaia-packages: .*\.gaia\/packages\.json is malformed.*Next step: /
    );
  });

  test('a missing descriptor is DESCRIPTOR_INVALID naming the descriptor path', () => {
    const result = loadPackages(rootFor('descriptor-missing'));

    expect(result.ok).toBe(false);
    expect(result).toMatchObject({code: 'DESCRIPTOR_INVALID'});
    expect(!result.ok && result.message).toContain(
      'frontend/gaia.package.json is missing'
    );
  });

  test('a registry that is a directory is malformed, not the built-in default', () => {
    const root = path.join(SCRATCH, 'registry-is-directory');
    mkdirSync(path.join(root, '.gaia/packages.json'), {recursive: true});

    expect(loadPackages(root)).toMatchObject({
      code: 'REGISTRY_MALFORMED',
      ok: false,
    });
  });

  test('a hostile registry path is malformed and runs nothing', () => {
    const root = path.join(SCRATCH, 'hostile');
    const marker = path.join(SCRATCH, 'pwned');
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    writeFileSync(
      path.join(root, '.gaia/packages.json'),
      JSON.stringify([{name: 'frontend', path: `frontend"; touch ${marker}`}])
    );

    expect(loadPackages(root)).toMatchObject({
      code: 'REGISTRY_MALFORMED',
      ok: false,
    });
    expect(existsSync(marker)).toBe(false);
  });
});

describe('built-in default', () => {
  test('registry absent: source is builtin, the committed descriptor drives it, frontend/app matches and root app does not', () => {
    const root = path.join(SCRATCH, 'absent');
    writeBuiltinDescriptor(root);
    const result = loadPackages(root);

    expect(result.ok && result.source).toBe('builtin');
    const patterns =
      result.ok ? repoRegExps(result.packages, 'tddUnitTests') : [];
    expect(patterns.some((p) => p.test('frontend/app/utils/x.test.ts'))).toBe(
      true
    );
    expect(patterns.some((p) => p.test('app/utils/x.test.ts'))).toBe(false);
  });

  test('the built-in registry is frontend at frontend', () => {
    expect(BUILTIN_REGISTRY).toEqual([{name: 'frontend', path: 'frontend'}]);
  });

  test('the committed registry loads clean from the repo root', () => {
    expect(loadPackages(REPO_ROOT)).toMatchObject({
      ok: true,
      source: 'registry',
    });
  });
});

describe('the web stack', () => {
  test('a two-member registry reports exactly the web member', () => {
    const result = loadPackages(rootFor('non-web-all-empty'));

    expect(result.ok).toBe(true);
    const packages = result.ok ? result.packages : [];
    expect(webMembers(packages).map((p) => p.name)).toEqual(['frontend']);
    expect(packages.map(wantsGeneratedSettings)).toEqual([true, false]);
  });

  test('generatedSettings opts a non-web member in', () => {
    const result = loadPackages(rootFor('generated-settings-non-web'));

    expect(result.ok && webMembers(result.packages)).toEqual([]);
    expect(result.ok && result.packages.map(wantsGeneratedSettings)).toEqual([
      true,
    ]);
  });

  test('the committed descriptor is reported web-stack', () => {
    const result = loadPackages(REPO_ROOT);

    expect(result.ok && webMembers(result.packages).map((p) => p.name)).toEqual(
      ['frontend']
    );
  });

  test('a stack other than web fails with DESCRIPTOR_INVALID naming the field', () => {
    const result = loadPackages(rootFor('descriptor-stack-invalid'));

    expect(result).toMatchObject({code: 'DESCRIPTOR_INVALID', ok: false});
    expect(!result.ok && result.message).toContain('stack must be "web"');
  });

  test('a non-boolean generatedSettings fails with DESCRIPTOR_INVALID naming the field', () => {
    const result = loadPackages(
      rootFor('descriptor-generated-settings-invalid')
    );

    expect(result).toMatchObject({code: 'DESCRIPTOR_INVALID', ok: false});
    expect(!result.ok && result.message).toContain(
      'generatedSettings must be a boolean'
    );
  });
});

describe('empty glob lists', () => {
  test('an all-empty member adds no pattern except its whole-member preCommitSource', () => {
    const result = loadPackages(rootFor('non-web-all-empty'));
    const packages = result.ok ? result.packages.slice(1) : [];

    expect(repoRegExps(packages, 'tddUnitTests')).toEqual([]);
    expect(repoRegExps(packages, 'dependencyManifests')).toEqual([]);
    const [pattern] = repoRegExps(packages, 'preCommitSource');
    expect(pattern?.test('packages/lib/deep/x.md')).toBe(true);
    expect(pattern?.test('packages/libx/x.md')).toBe(false);
  });
});

describe('registrable paths', () => {
  test.each(['apps/web', '.'])('%s is registrable', (candidate) => {
    expect(isRegistrablePath(candidate)).toBe(true);
  });

  test.each(['apps/Legacy', '.gaia/cli'])('%s is refused', (candidate) => {
    expect(isRegistrablePath(candidate)).toBe(false);
  });
});

describe('glob helpers', () => {
  test('joinGlob keeps a root-package glob and prefixes any other', () => {
    expect(joinGlob('.', 'app/**')).toBe('app/**');
    expect(joinGlob('apps/web', 'app/**')).toBe('apps/web/app/**');
  });

  test('** + / matches zero directories: the direct child of the directory', () => {
    expect(globToRegExp('app/**/*.test.ts').test('app/x.test.ts')).toBe(true);
    expect(globToRegExp('app/**/*.test.ts').test('app/a/b/x.test.ts')).toBe(
      true
    );
  });

  test('* never crosses a slash', () => {
    expect(globToRegExp('app/*.ts').test('app/a/x.ts')).toBe(false);
  });
});

describe('corpus directory', () => {
  test('corpus directory exists', () => {
    expect(existsSync(CORPUS_DIRECTORY)).toBe(true);
  });
});
