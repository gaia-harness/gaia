/**
 * Strategy: write temporary package.json files (baseline / latest / current,
 * plus deferred baselines), run the handler, and assert the JSON verdict
 * report. The command is read-only, so there are no on-disk effects to assert.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {occupiedBucket, VERDICT_ROWS} from './field-verdict-table-fixture.js';
import type {FieldMergeReport} from './field-verdict.js';
import {run} from './merge-package.js';

type Which = 'baseline' | 'current' | 'latest';

let root = '';
let outputs: string[] = [];
let errors: string[] = [];

const filePath = (name: string): string => path.join(root, `${name}.json`);

const write = (name: string, contents: unknown): string => {
  writeFileSync(
    filePath(name),
    typeof contents === 'string' ? contents : JSON.stringify(contents),
    'utf8'
  );

  return filePath(name);
};

const argvFor = (extra: string[] = []): string[] => [
  '--baseline',
  filePath('baseline'),
  '--latest',
  filePath('latest'),
  '--current',
  filePath('current'),
  ...extra,
  '--json',
];

const merge = (
  files: Record<Which, unknown>,
  extra: string[] = []
): FieldMergeReport => {
  for (const [name, contents] of Object.entries(files)) write(name, contents);

  expect(run(argvFor(extra))).toBe(0);

  return JSON.parse(outputs.join('').trim()) as FieldMergeReport;
};

const devDependencies = (value: number | undefined): unknown =>
  value === undefined ? {} : {devDependencies: {vite: `^${value}.0.0`}};

beforeEach(() => {
  root = mkdtempSync(path.join(tmpdir(), 'gaia-field-merge-package-'));
  outputs = [];
  errors = [];
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    outputs.push(String(chunk));

    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
    errors.push(String(chunk));

    return true;
  });
});

afterEach(() => {
  vi.restoreAllMocks();
  rmSync(root, {force: true, recursive: true});
});

describe('update merge-package verdict table', () => {
  test.each(VERDICT_ROWS)('$name', (row) => {
    const report = merge({
      baseline: devDependencies(row.baseline),
      current: devDependencies(row.adopter),
      latest: devDependencies(row.latest),
    });

    expect(occupiedBucket(report)).toBe(row.expected);

    expect(report.applied[0]?.reason).toBe(row.reason);
  });

  test('a GAIA-changed key the adopter removed is kept removed and never applied', () => {
    const report = merge({
      baseline: {dependencies: {zod: '^3.0.0'}},
      current: {dependencies: {}},
      latest: {dependencies: {zod: '^4.0.0'}},
    });

    expect(report.applied).toEqual([]);
    expect(report.keptRemoved).toHaveLength(1);
  });

  test('identity fields and unmanaged sections are never visited', () => {
    const report = merge({
      baseline: {
        name: 'gaia',
        optionalDependencies: {a: '1.0.0'},
        version: '1.0.0',
      },
      current: {
        name: 'mine',
        optionalDependencies: {a: '9.0.0'},
        version: '0.1.0',
      },
      latest: {
        name: 'gaia',
        optionalDependencies: {a: '2.0.0'},
        version: '2.0.0',
      },
    });

    expect(occupiedBucket(report)).toBe('none');
  });

  test('packageManager merges as one value', () => {
    const report = merge({
      baseline: {packageManager: 'pnpm@11.0.0'},
      current: {packageManager: 'pnpm@11.0.0'},
      latest: {packageManager: 'pnpm@11.3.0'},
    });

    expect(report.applied).toEqual([
      {
        adopter: 'pnpm@11.0.0',
        baseline: 'pnpm@11.0.0',
        key: 'packageManager',
        kind: 'key',
        latest: 'pnpm@11.3.0',
        reason: 'changed',
      },
    ]);
  });
});

describe('update merge-package recommendations', () => {
  test.each(
    (
      [
        {
          conflict: {
            recommendation: {option: 'higher', side: 'gaia', value: '^5.2.0'},
            versionValued: true,
          },
          files: {
            baseline: {dependencies: {react: '^5.0.0'}},
            current: {dependencies: {react: '^5.1.0'}},
            latest: {dependencies: {react: '^5.2.0'}},
          },
          name: 'a dependency re-pin below GAIA recommends the higher GAIA range',
        },
        {
          conflict: {recommendation: {option: 'higher', side: 'adopter'}},
          files: {
            baseline: {devDependencies: {vite: '^5.0.0'}},
            current: {devDependencies: {vite: '~6.0.0'}},
            latest: {devDependencies: {vite: '^5.9.0'}},
          },
          name: 'an adopter major ahead of GAIA recommends the adopter side',
        },
        {
          conflict: {
            recommendation: {option: 'higher', side: 'gaia'},
            versionValued: true,
          },
          files: {
            baseline: {engines: {node: '>=20'}},
            current: {engines: {node: '>=22'}},
            latest: {engines: {node: '>=24'}},
          },
          name: 'an engines conflict is version valued',
        },
        {
          conflict: {
            recommendation: {
              option: 'higher',
              side: 'gaia',
              value: 'pnpm@11.3.0',
            },
            versionValued: true,
          },
          files: {
            baseline: {packageManager: 'pnpm@11.0.0'},
            current: {packageManager: 'pnpm@11.2.0+sha512.abc'},
            latest: {packageManager: 'pnpm@11.3.0'},
          },
          name: 'a packageManager conflict compares versions without the hash',
        },
        {
          conflict: {
            recommendation: {option: 'keep', value: 'mine'},
            versionValued: false,
          },
          files: {
            baseline: {scripts: {build: 'a'}},
            current: {scripts: {build: 'mine'}},
            latest: {scripts: {build: 'b'}},
          },
          name: 'a scripts conflict is not version valued and recommends keep',
        },
      ] satisfies {
        conflict: object;
        files: Record<Which, unknown>;
        name: string;
      }[]
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {conflict, files}) => {
    const report = merge(files);

    expect(report.conflicts[0]).toMatchObject(conflict);
    expect(report.conflicts[0]?.recommendation?.reason).not.toBe('');
  });
});

const deferredFixture = (): Record<Which, unknown> => ({
  baseline: {devDependencies: {vite: '^2.0.0'}},
  current: {devDependencies: {vite: '^1.0.0'}},
  latest: {devDependencies: {vite: '^2.0.0'}},
});

describe('update merge-package deferred baselines', () => {
  test('a key deferred where it was 1 merges against that bundle and applies', () => {
    const deferred = write('deferred', {devDependencies: {vite: '^1.0.0'}});
    const report = merge(deferredFixture(), [
      '--deferred-baseline',
      `devDependencies.vite=${deferred}`,
    ]);

    expect(report.applied).toHaveLength(1);
    expect(report.applied[0]).toMatchObject({
      baseline: '^1.0.0',
      key: 'vite',
      reason: 'changed',
    });
  });

  test('without the deferred baseline the same key is a no-op', () => {
    expect(occupiedBucket(merge(deferredFixture()))).toBe('none');
  });

  test('a scoped package key splits its section at the first dot', () => {
    const deferred = write('deferred', {
      devDependencies: {'@types/node': '^1.0.0'},
    });
    const report = merge(
      {
        baseline: {devDependencies: {'@types/node': '^2.0.0'}},
        current: {devDependencies: {'@types/node': '^1.0.0'}},
        latest: {devDependencies: {'@types/node': '^2.0.0'}},
      },
      ['--deferred-baseline', `devDependencies.@types/node=${deferred}`]
    );

    expect(report.applied[0]).toMatchObject({
      key: '@types/node',
      section: 'devDependencies',
    });
  });
});

describe('update merge-package errors', () => {
  test.each(
    (
      [
        {
          argv: () =>
            argvFor([
              '--deferred-baseline',
              `devDependencies.vite=${path.join(root, 'absent.json')}`,
            ]),
          code: 'package_file_missing',
          files: deferredFixture(),
          name: 'a missing deferred file exits non-zero with a structured error',
        },
        {
          argv: () => argvFor(),
          code: 'package_file_missing',
          files: {baseline: {}, latest: {}},
          name: 'a missing file exits non-zero with a structured error',
        },
        {
          argv: () => argvFor(),
          code: 'package_parse_failed',
          files: {baseline: {}, current: '{ not json', latest: {}},
          name: 'invalid JSON exits non-zero with a structured error',
        },
        {
          argv: () => ['--json'],
          code: 'invalid_arguments',
          files: {},
          name: 'a missing required flag exits non-zero',
        },
      ] satisfies {
        argv: () => string[];
        code: string;
        files: Partial<Record<'deferred' | Which, unknown>>;
        name: string;
      }[]
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {argv, code, files}) => {
    for (const [name, contents] of Object.entries(files)) write(name, contents);

    expect(run(argv())).not.toBe(0);
    expect(errors.join('')).toContain(code);
  });

  test('prints a human summary without --json', () => {
    write('baseline', {dependencies: {a: '1.0.0'}});
    write('latest', {dependencies: {a: '2.0.0'}});
    write('current', {dependencies: {a: '1.0.0'}});

    expect(
      run([
        '--baseline',
        filePath('baseline'),
        '--latest',
        filePath('latest'),
        '--current',
        filePath('current'),
      ])
    ).toBe(0);
    expect(outputs.join('')).toContain('dependencies.a');
  });
});
