/**
 * Strategy: write three temporary `pnpm-workspace.yaml` files (baseline /
 * latest / current), run the handler, and assert the JSON verdict report.
 * The command is a read-only verdict oracle: it never writes the YAML, so
 * there are no on-disk side effects to assert (the `/update-gaia` skill
 * applies `applied[]` via the Edit tool to preserve comments and order).
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {occupiedBucket, VERDICT_ROWS} from './field-verdict-table-fixture.js';
import {run} from './merge-workspace.js';
import type {WorkspaceMergeReport} from './merge-workspace.js';

type Sandbox = {
  baselinePath: string;
  cleanup: () => void;
  currentPath: string;
  latestPath: string;
  root: string;
  write: (which: 'baseline' | 'current' | 'latest', contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-field-merge-workspace-'));
  const baselinePath = path.join(root, 'baseline.yaml');
  const latestPath = path.join(root, 'latest.yaml');
  const currentPath = path.join(root, 'current.yaml');

  return {
    baselinePath,
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    currentPath,
    latestPath,
    root,
    write: (which, contents): void => {
      const target =
        which === 'baseline' ? baselinePath
        : which === 'latest' ? latestPath
        : currentPath;
      writeFileSync(target, contents, 'utf8');
    },
  };
};

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const parseJson = (outputs: readonly string[]): WorkspaceMergeReport =>
  JSON.parse(outputs.join('').trim()) as WorkspaceMergeReport;

const argv = (sandbox: Sandbox): string[] => [
  '--baseline',
  sandbox.baselinePath,
  '--latest',
  sandbox.latestPath,
  '--current',
  sandbox.currentPath,
  '--json',
];

describe('update merge-workspace', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('version-only release: managed keys identical → all buckets empty', () => {
    const yaml = 'minimumReleaseAge: 10080\ntrustPolicy: no-downgrade\n';
    sandbox.write('baseline', yaml);
    sandbox.write('latest', yaml);
    sandbox.write('current', yaml);

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
  });

  test('scalar apply: GAIA bumped, adopter undrifted → applied with latest value', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 20160\n');
    sandbox.write('current', 'minimumReleaseAge: 10080\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([
      {
        adopter: 10_080,
        baseline: 10_080,
        key: 'minimumReleaseAge',
        kind: 'key',
        latest: 20_160,
        reason: 'changed',
      },
    ]);
    expect(report.conflicts).toEqual([]);
  });

  test('scalar conflict: GAIA changed, adopter re-pinned independently → conflict, adopter kept', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 20160\n');
    sandbox.write('current', 'minimumReleaseAge: 5000\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([
      {
        adopter: 5000,
        baseline: 10_080,
        key: 'minimumReleaseAge',
        kind: 'key',
        latest: 20_160,
        recommendation: {
          option: 'keep',
          reason: expect.any(String),
          value: 5000,
        },
        versionValued: false,
      },
    ]);
  });

  test('GAIA-added managed key the adopter lacks → applied (added)', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write(
      'latest',
      'minimumReleaseAge: 10080\nstrictPeerDependencies: false\n'
    );
    sandbox.write('current', 'minimumReleaseAge: 10080\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([
      {
        key: 'strictPeerDependencies',
        kind: 'key',
        latest: false,
        reason: 'added',
      },
    ]);
  });

  test('auditConfig is managed: an accepted advisory GAIA adds → applied (added)', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 4320\n');
    sandbox.write(
      'latest',
      'minimumReleaseAge: 4320\nauditConfig:\n  ignoreGhsas:\n    - GHSA-aaaa-bbbb-cccc\n'
    );
    sandbox.write('current', 'minimumReleaseAge: 4320\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([
      {
        key: 'auditConfig',
        kind: 'key',
        latest: {ignoreGhsas: ['GHSA-aaaa-bbbb-cccc']},
        reason: 'added',
      },
    ]);
  });

  test('adopter removed a key GAIA then changed → keptRemoved, never re-added', () => {
    sandbox.write('baseline', 'trustPolicy: no-downgrade\n');
    sandbox.write('latest', 'trustPolicy: strict\n');
    sandbox.write('current', 'savePrefix: ""\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    // savePrefix in current only (not in B or L) is never visited.
    expect(report.keptRemoved).toEqual([
      {
        baseline: 'no-downgrade',
        key: 'trustPolicy',
        kind: 'key',
        latest: 'strict',
      },
    ]);
  });

  test('overrides map: per-entry apply, adopter-added entry untouched', () => {
    sandbox.write(
      'baseline',
      "overrides:\n  'qs': '>=6.15.2'\n  'ws': '>=8.20.1'\n"
    );
    sandbox.write(
      'latest',
      "overrides:\n  'qs': '>=6.16.0'\n  'ws': '>=8.20.1'\n"
    );
    sandbox.write(
      'current',
      "overrides:\n  'qs': '>=6.15.2'\n  'ws': '>=8.20.1'\n  'my-dep': '1.0.0'\n"
    );

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    // qs applied; ws unchanged (noop); my-dep adopter-only → never visited.
    expect(report.applied).toEqual([
      {
        adopter: '>=6.15.2',
        baseline: '>=6.15.2',
        key: 'qs',
        kind: 'entry',
        latest: '>=6.16.0',
        reason: 'changed',
        section: 'overrides',
      },
    ]);
    expect(report.conflicts).toEqual([]);
  });

  test('overrides map: adopter re-pinned an entry → conflict, adopter kept', () => {
    sandbox.write('baseline', "overrides:\n  'qs': '>=6.15.2'\n");
    sandbox.write('latest', "overrides:\n  'qs': '>=6.16.0'\n");
    sandbox.write('current', "overrides:\n  'qs': '>=6.99.0'\n");

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.conflicts).toEqual([
      {
        adopter: '>=6.99.0',
        baseline: '>=6.15.2',
        key: 'qs',
        kind: 'entry',
        latest: '>=6.16.0',
        recommendation: {
          option: 'higher',
          reason: expect.any(String),
          side: 'adopter',
          value: '>=6.99.0',
        },
        section: 'overrides',
        versionValued: true,
      },
    ]);
  });

  test('allowBuilds map: boolean flip applied; GAIA-added build → applied (added)', () => {
    sandbox.write('baseline', 'allowBuilds:\n  core-js-pure: true\n');
    sandbox.write(
      'latest',
      'allowBuilds:\n  core-js-pure: false\n  msw: true\n'
    );
    sandbox.write('current', 'allowBuilds:\n  core-js-pure: true\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([
      {
        adopter: true,
        baseline: true,
        key: 'core-js-pure',
        kind: 'entry',
        latest: false,
        reason: 'changed',
        section: 'allowBuilds',
      },
      {
        key: 'msw',
        kind: 'entry',
        latest: true,
        reason: 'added',
        section: 'allowBuilds',
      },
    ]);
  });

  test('list key: whole-value apply when adopter undrifted', () => {
    sandbox.write('baseline', "publicHoistPattern:\n  - '*stylelint*'\n");
    sandbox.write(
      'latest',
      "publicHoistPattern:\n  - '*stylelint*'\n  - 'prettier-plugin-*'\n"
    );
    sandbox.write('current', "publicHoistPattern:\n  - '*stylelint*'\n");

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([
      {
        adopter: ['*stylelint*'],
        baseline: ['*stylelint*'],
        key: 'publicHoistPattern',
        kind: 'key',
        latest: ['*stylelint*', 'prettier-plugin-*'],
        reason: 'changed',
      },
    ]);
  });

  test('list key: adopter extended the list → conflict (whole-value drift)', () => {
    sandbox.write('baseline', "publicHoistPattern:\n  - '*stylelint*'\n");
    sandbox.write(
      'latest',
      "publicHoistPattern:\n  - '*stylelint*'\n  - 'prettier-plugin-*'\n"
    );
    sandbox.write(
      'current',
      "publicHoistPattern:\n  - '*stylelint*'\n  - 'my-tool-*'\n"
    );

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.conflicts).toEqual([
      {
        adopter: ['*stylelint*', 'my-tool-*'],
        baseline: ['*stylelint*'],
        key: 'publicHoistPattern',
        kind: 'key',
        latest: ['*stylelint*', 'prettier-plugin-*'],
        recommendation: {
          option: 'keep',
          reason: expect.any(String),
          value: ['*stylelint*', 'my-tool-*'],
        },
        versionValued: false,
      },
    ]);
  });

  test('managed section absent in baseline and latest: adopter overrides untouched', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 10080\n');
    sandbox.write('current', "overrides:\n  'foo': '1.0.0'\n");

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
  });

  test('non-managed top-level key is ignored entirely', () => {
    sandbox.write('baseline', 'nodeLinker: hoisted\n');
    sandbox.write('latest', 'nodeLinker: isolated\n');
    sandbox.write('current', 'nodeLinker: hoisted\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
  });

  test('malformed adopter YAML → non-zero exit with structured error', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 20160\n');
    sandbox.write('current', 'overrides:\n  qs: [unterminated\n');

    const exit = run(argv(sandbox));
    expect(exit).not.toBe(0);

    const stderr = stdio.errors.join('');
    expect(stderr).toContain('workspace_parse_failed');
  });

  test('missing file → non-zero exit with structured error', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 20160\n');
    // current never written.

    const exit = run(argv(sandbox));
    expect(exit).not.toBe(0);

    const stderr = stdio.errors.join('');
    expect(stderr).toContain('workspace_file_missing');
  });

  test('human output (no --json) prints counts', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 20160\n');
    sandbox.write('current', 'minimumReleaseAge: 10080\n');

    const exit = run([
      '--baseline',
      sandbox.baselinePath,
      '--latest',
      sandbox.latestPath,
      '--current',
      sandbox.currentPath,
    ]);
    expect(exit).toBe(0);

    const out = stdio.outputs.join('');
    expect(out).toContain('Applied:');
    expect(out).toContain('1');
  });

  test('--help prints usage and exits 0', () => {
    const exit = run(['--help']);
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('merge-workspace');
  });

  test('an unknown flag exits non-zero with invalid_arguments', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 20160\n');
    sandbox.write('current', 'minimumReleaseAge: 10080\n');

    const exit = run([...argv(sandbox), '--nope']);

    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('invalid_arguments');
  });

  test('verdict items sort by section then key across a U+0000 separator', () => {
    // Collation ignores U+0000 entirely, so ordering is by section-then-key
    // with no separator weight of its own: the `allowBuilds` entry sorts ahead
    // of the section-less `trustPolicy` even though triples are built the other
    // way round. Any visible separator would sort the section-less item first.
    sandbox.write(
      'baseline',
      'trustPolicy: none\nallowBuilds:\n  esbuild: false\n'
    );
    sandbox.write(
      'latest',
      'trustPolicy: all\nallowBuilds:\n  esbuild: true\n'
    );
    sandbox.write(
      'current',
      'trustPolicy: none\nallowBuilds:\n  esbuild: false\n'
    );

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied.map((item) => [item.section, item.key])).toEqual([
      ['allowBuilds', 'esbuild'],
      [undefined, 'trustPolicy'],
    ]);
  });
});

const ageYaml = (value: number | undefined): string =>
  value === undefined ?
    'nodeLinker: hoisted\n'
  : `minimumReleaseAge: ${value}\n`;

describe('update merge-workspace verdict table', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test.each(VERDICT_ROWS)('$name', (row) => {
    sandbox.write('baseline', ageYaml(row.baseline));
    sandbox.write('latest', ageYaml(row.latest));
    sandbox.write('current', ageYaml(row.adopter));

    expect(run(argv(sandbox))).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(occupiedBucket(report)).toBe(row.expected);

    expect(report.applied[0]?.reason).toBe(row.reason);
  });

  test('a GAIA-changed key the adopter removed is kept removed and never applied', () => {
    sandbox.write('baseline', 'trustPolicy: no-downgrade\n');
    sandbox.write('latest', 'trustPolicy: strict\n');
    sandbox.write('current', 'nodeLinker: hoisted\n');

    expect(run(argv(sandbox))).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.keptRemoved).toHaveLength(1);
  });

  test('a workspace-setting conflict and an allowBuilds conflict are not version valued', () => {
    sandbox.write(
      'baseline',
      'minimumReleaseAge: 1\nallowBuilds:\n  msw: true\n'
    );
    sandbox.write(
      'latest',
      'minimumReleaseAge: 2\nallowBuilds:\n  msw: false\n'
    );
    sandbox.write(
      'current',
      'minimumReleaseAge: 3\nallowBuilds:\n  msw: null\n'
    );

    expect(run(argv(sandbox))).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.conflicts).toHaveLength(2);

    for (const item of report.conflicts) {
      expect(item.versionValued).toBe(false);
      expect(item.recommendation?.option).toBe('keep');
      expect(item.recommendation?.reason).not.toBe('');
    }
  });

  test('an overrides conflict is version valued and recommends the higher range', () => {
    sandbox.write('baseline', "overrides:\n  qs: '>=6.0.0'\n");
    sandbox.write('latest', "overrides:\n  qs: '>=6.5.0'\n");
    sandbox.write('current', "overrides:\n  qs: '>=6.2.0'\n");

    expect(run(argv(sandbox))).toBe(0);

    expect(parseJson(stdio.outputs).conflicts[0]).toMatchObject({
      recommendation: {option: 'higher', side: 'gaia', value: '>=6.5.0'},
      versionValued: true,
    });
  });
});

describe('update merge-workspace deferred baselines', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  const deferredPath = (): string => path.join(sandbox.root, 'deferred.yaml');

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
    sandbox.write('baseline', ageYaml(2));
    sandbox.write('latest', ageYaml(2));
    sandbox.write('current', ageYaml(1));
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('a key deferred where it was 1 applies against that bundle', () => {
    writeFileSync(deferredPath(), ageYaml(1), 'utf8');

    expect(
      run([
        ...argv(sandbox),
        '--deferred-baseline',
        `minimumReleaseAge=${deferredPath()}`,
      ])
    ).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toHaveLength(1);
    expect(report.applied[0]).toMatchObject({
      baseline: 1,
      key: 'minimumReleaseAge',
      reason: 'changed',
    });
  });

  test('without the deferred baseline the same key is a no-op', () => {
    expect(run(argv(sandbox))).toBe(0);
    expect(occupiedBucket(parseJson(stdio.outputs))).toBe('none');
  });

  test('a map entry key splits its section at the first dot', () => {
    sandbox.write('baseline', "overrides:\n  '@scope/pkg': '>=2.0.0'\n");
    sandbox.write('latest', "overrides:\n  '@scope/pkg': '>=2.0.0'\n");
    sandbox.write('current', "overrides:\n  '@scope/pkg': '>=1.0.0'\n");
    writeFileSync(
      deferredPath(),
      "overrides:\n  '@scope/pkg': '>=1.0.0'\n",
      'utf8'
    );

    expect(
      run([
        ...argv(sandbox),
        '--deferred-baseline',
        `overrides.@scope/pkg=${deferredPath()}`,
      ])
    ).toBe(0);

    expect(parseJson(stdio.outputs).applied[0]).toMatchObject({
      key: '@scope/pkg',
      section: 'overrides',
    });
  });

  test('a missing deferred file exits non-zero with a structured error', () => {
    const exit = run([
      ...argv(sandbox),
      '--deferred-baseline',
      `minimumReleaseAge=${deferredPath()}`,
    ]);

    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('workspace_file_missing');
  });
});
