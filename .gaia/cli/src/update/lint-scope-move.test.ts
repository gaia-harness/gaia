/**
 * Strategy: drive the real package merge over a project that still carries
 * the old lint package, and assert the outcome is either "the new dependency
 * applied" or "a conflict reported", never neither (configs importing the new
 * package while package.json lacks it). The old package is removed only when
 * the new one lands, so a conflict never leaves the project with neither.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import type {FieldMergeReport} from './field-verdict.js';
import {run} from './merge-package.js';

type PackageJson = {
  dependencies?: Record<string, string>;
  devDependencies?: Record<string, string>;
};

const OLD_LINT = ['@gaia', 'react/lint'].join('-');
const NEW_LINT = '@gaia-harness/lint';
const OWNED_CONFIGS = [
  'frontend/eslint.config.mjs',
  'frontend/prettier.config.mjs',
  'frontend/stylelint.config.mjs',
  'prettier.config.mjs',
];

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);

// Read from the release manifest, not pinned: the real-release-file tests
// compare against it, and every lint bump moves it.
const LINT_VERSION =
  (
    JSON.parse(
      readFileSync(path.join(repoRoot, 'frontend/package.json'), 'utf8')
    ) as PackageJson
  ).devDependencies?.[NEW_LINT] ?? '';

const baseline: PackageJson = {
  devDependencies: {[OLD_LINT]: '3.0.3', prettier: '3.9.10'},
};
const latestInline: PackageJson = {
  devDependencies: {[NEW_LINT]: LINT_VERSION, prettier: '3.9.10'},
};
const currentUntouched: PackageJson = baseline;
const currentEdited: PackageJson = {
  devDependencies: {[OLD_LINT]: '3.0.4', prettier: '3.9.10'},
};
const currentConflicting: PackageJson = {
  devDependencies: {...baseline.devDependencies, [NEW_LINT]: '0.0.1'},
};

let temporaryRoot = '';
let outputs: string[] = [];

const filePath = (name: string): string =>
  path.join(temporaryRoot, `${name}.json`);

const mergeWith = (
  files: {current: unknown; latest: unknown},
  extra: string[] = ['--json']
): string => {
  writeFileSync(filePath('baseline'), JSON.stringify(baseline));
  writeFileSync(filePath('latest'), JSON.stringify(files.latest));
  writeFileSync(filePath('current'), JSON.stringify(files.current));
  outputs = [];

  expect(
    run([
      '--baseline',
      filePath('baseline'),
      '--latest',
      filePath('latest'),
      '--current',
      filePath('current'),
      ...extra,
    ])
  ).toBe(0);

  return outputs.join('');
};

const mergeReport = (files: {
  current: unknown;
  latest: unknown;
}): FieldMergeReport => JSON.parse(mergeWith(files).trim()) as FieldMergeReport;

const wasAdded = (report: FieldMergeReport): boolean =>
  report.applied.some(
    (item) =>
      (item.section === 'devDependencies' || item.section === 'dependencies') &&
      item.key === NEW_LINT &&
      item.latest === LINT_VERSION
  );

const wasRemoved = (report: FieldMergeReport): boolean =>
  report.applied.some(
    (item) =>
      item.section === 'devDependencies' &&
      item.key === OLD_LINT &&
      item.reason === 'removed'
  );

const landsOnNewLint = (report: FieldMergeReport): boolean =>
  wasAdded(report) || report.conflicts.length > 0;

const readRepoJson = (relativePath: string): PackageJson =>
  JSON.parse(
    readFileSync(path.join(repoRoot, relativePath), 'utf8')
  ) as PackageJson;

beforeEach(() => {
  temporaryRoot = mkdtempSync(path.join(tmpdir(), 'gaia-lint-scope-move-'));
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    outputs.push(String(chunk));

    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
});

afterEach(() => {
  vi.restoreAllMocks();
  rmSync(temporaryRoot, {force: true, recursive: true});
});

describe('package.json merge', () => {
  test('an untouched lint pin gains the new package and has the old one removed', () => {
    const report = mergeReport({
      current: currentUntouched,
      latest: latestInline,
    });

    expect(wasAdded(report)).toBe(true);
    expect(wasRemoved(report)).toBe(true);
    expect(report.removedUpstream.map((item) => item.key)).not.toContain(
      OLD_LINT
    );
    expect(report.conflicts.map((item) => item.key)).not.toContain(OLD_LINT);
  });

  test('an edited lint pin is removed once the new package lands', () => {
    const report = mergeReport({
      current: currentEdited,
      latest: latestInline,
    });

    expect(wasAdded(report)).toBe(true);
    expect(wasRemoved(report)).toBe(true);
  });

  test('a project that does not carry the old package gets no removal', () => {
    const report = mergeReport({
      current: {devDependencies: {prettier: '3.9.10'}},
      latest: latestInline,
    });

    expect(wasAdded(report)).toBe(true);
    expect(
      [...report.applied, ...report.removedUpstream].map((item) => item.key)
    ).not.toContain(OLD_LINT);
  });
});

describe('merge outcome edge cases', () => {
  test('an adopter already carrying a differing new pin gets a conflict naming the package', () => {
    const report = mergeReport({
      current: currentConflicting,
      latest: latestInline,
    });

    expect(report.conflicts.map((item) => item.key)).toContain(NEW_LINT);
    expect(landsOnNewLint(report)).toBe(true);
    expect(wasRemoved(report)).toBe(false);
    expect(report.removedUpstream.map((item) => item.key)).toContain(OLD_LINT);

    const human = mergeWith(
      {current: currentConflicting, latest: latestInline},
      []
    );

    expect(human).toContain('merge-package');
    expect(human).toContain(NEW_LINT);
  });

  test('the mixed-state guard fails when the new package is missing from the release file', () => {
    const real = readRepoJson('frontend/package.json');
    const withoutNewLint: PackageJson = {
      ...real,
      devDependencies: Object.fromEntries(
        Object.entries(real.devDependencies ?? {}).filter(
          ([key]) => key !== NEW_LINT
        )
      ),
    };
    const report = mergeReport({
      current: currentUntouched,
      latest: withoutNewLint,
    });

    expect(landsOnNewLint(report)).toBe(false);
  });
});

describe('real release files', () => {
  test.each(['frontend/package.json', 'package.json'])(
    'the untouched old lint pin merged into %s swaps to the new package',
    (relativePath) => {
      const report = mergeReport({
        current: currentUntouched,
        latest: readRepoJson(relativePath),
      });

      expect(wasAdded(report)).toBe(true);
      expect(wasRemoved(report)).toBe(true);
    }
  );

  const manifest = JSON.parse(
    readFileSync(path.join(repoRoot, '.gaia/manifest.json'), 'utf8')
  ) as {files: Record<string, string>};

  test.each(OWNED_CONFIGS)('%s is owned by the release', (relativePath) => {
    expect(manifest.files[relativePath]).toBe('owned');
  });

  test.each(OWNED_CONFIGS)(
    '%s imports the new package and not the old one',
    (relativePath) => {
      const contents = readFileSync(path.join(repoRoot, relativePath), 'utf8');

      expect(contents).toContain(`'${NEW_LINT}`);
      expect(contents).not.toContain(OLD_LINT);
    }
  );
});
