/**
 * Strategy: `computeRegionMerge` is pure (no I/O), so most of the coverage
 * calls it directly with in-memory fixtures. `run` is covered only for flag
 * parsing and the error/exit paths, per AUDIT directive 3: the one-line JSON
 * verdict is the assertable surface, the working-tree consequences are the
 * skill's prose and are prose-verified elsewhere.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {computeRegionMerge, run} from './merge-region.js';
import type {RegionMergeReport} from './merge-region.js';
import {REGION_PLACEHOLDER} from './region-markers.js';

const START = '<!-- gaia:test:start -->';
const END = '<!-- gaia:test:end -->';

const placeholderCount = (body: string): number =>
  body.split('\n').filter((line) => line === REGION_PLACEHOLDER).length;

const soleLine = (lines: string[]): string => {
  const [line] = lines;
  if (line === undefined) throw new Error('expected exactly one line');

  return line;
};

describe('computeRegionMerge', () => {
  test('region-only divergence: verdict no-adopter-drift, all three sides masked region', () => {
    const baseline = ['old outside', START, 'region v1', END].join('\n');
    const latest = ['new outside', START, 'region v1', END].join('\n');
    const current = ['old outside', START, 'region v2', END].join('\n');

    const report = computeRegionMerge(baseline, latest, current, START, END);

    expect(report.verdict).toBe('no-adopter-drift');
    expect(report.markers.bailed).toBe(false);
    expect(report.markers.baseline).toEqual({masked: true, scan: 'region'});
    expect(report.markers.latest).toEqual({masked: true, scan: 'region'});
    expect(report.markers.current).toEqual({masked: true, scan: 'region'});
  });

  test('divergence inside and outside the region: verdict conflict, normalized bodies mask only the region', () => {
    const baseline = [
      'line0',
      START,
      'region baseline',
      END,
      'line-end-baseline',
    ].join('\n');
    const latest = [
      'line0',
      START,
      'region baseline',
      END,
      'line-end-latest',
    ].join('\n');
    const current = [
      'line0',
      START,
      'region current',
      END,
      'line-end-current',
    ].join('\n');

    const report = computeRegionMerge(baseline, latest, current, START, END);

    expect(report.verdict).toBe('conflict');
    expect(placeholderCount(report.normalized.current)).toBe(1);
    expect(placeholderCount(report.normalized.latest)).toBe(1);
    expect(report.normalized.current).not.toContain('region current');
    expect(report.normalized.current).not.toContain('region baseline');
    expect(report.normalized.latest).not.toContain('region baseline');
    expect(report.normalized.latest).not.toContain('region current');
    // The out-of-region hunk (the trailing line) survives normalization
    // identically to what a whole-file diff of the two raw sides produces.
    expect(report.normalized.current).toContain('line-end-current');
    expect(report.normalized.latest).toContain('line-end-latest');
  });

  test.each(
    (
      [
        {
          baseline: 'baseline body\n',
          current: [START, 'a', 'b'].join('\n'),
          latest: 'latest body\n',
          markers: {
            current: {detail: 'unbalanced', masked: false, scan: 'malformed'},
          },
          name: 'malformed working copy (unbalanced: start with no end) bails; verdict falls out of the raw comparison',
          verdict: 'conflict',
        },
        {
          baseline: 'baseline body\n',
          current: [START, 'a', START, 'b', END].join('\n'),
          latest: 'latest body\n',
          markers: {
            current: {
              detail: 'duplicate-start',
              masked: false,
              scan: 'malformed',
            },
          },
          name: 'malformed working copy (duplicate-start) bails the same way',
          verdict: 'conflict',
        },
        {
          baseline: 'baseline body\n',
          current: [END, 'a', START].join('\n'),
          latest: 'latest body\n',
          markers: {
            current: {detail: 'inverted', masked: false, scan: 'malformed'},
          },
          name: 'malformed working copy (inverted) bails the same way',
          verdict: 'conflict',
        },
        {
          // The baseline is the duplicate-start side.
          baseline: [START, 'a', START, 'b', END].join('\n'),
          current: ['outside', START, 'region', END].join('\n'),
          latest: ['outside', START, 'region', END].join('\n'),
          markers: {
            baseline: {
              detail: 'duplicate-start',
              masked: false,
              scan: 'malformed',
            },
            current: {masked: false, scan: 'region'},
          },
          name: 'malformed baseline only: global bail, baseline carries the detail, current reports its own well-formed region unmasked',
          verdict: 'already-latest',
        },
      ] satisfies {
        baseline: string;
        current: string;
        latest: string;
        markers: Partial<Record<'baseline' | 'current', object>>;
        name: string;
        verdict: string;
      }[]
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {baseline, current, latest, markers, verdict}) => {
    const report = computeRegionMerge(baseline, latest, current, START, END);

    expect(report.markers.bailed).toBe(true);

    for (const [side, expected] of Object.entries(markers)) {
      expect(report.markers[side as keyof typeof markers]).toEqual(expected);
    }
    expect(report.normalized).toEqual({baseline, current, latest});
    expect(report.verdict).toBe(verdict);
  });

  test('pre-region baseline (UAT-009): baseline and current carry no markers, latest does; classifies no-adopter-drift', () => {
    const plain = ['plain content', 'no markers here'].join('\n');
    const baseline = plain;
    const current = plain;
    const latest = [
      'plain content',
      START,
      'new region',
      END,
      'no markers here',
    ].join('\n');

    const report = computeRegionMerge(baseline, latest, current, START, END);

    expect(report.verdict).toBe('no-adopter-drift');
    expect(report.markers.bailed).toBe(false);
    expect(report.markers.baseline).toEqual({masked: false, scan: 'absent'});
    expect(report.markers.current).toEqual({masked: false, scan: 'absent'});
    expect(report.markers.latest).toEqual({masked: true, scan: 'region'});
  });

  test('baseline predates the region, working copy carries one (UAT-019): not no-adopter-drift', () => {
    const baseline = ['plain content', 'no markers here'].join('\n');
    const current = [
      'plain content',
      START,
      'hand-written region',
      END,
      'no markers here',
    ].join('\n');
    const latest = [
      'plain content',
      START,
      'release region',
      END,
      'no markers here',
    ].join('\n');

    const report = computeRegionMerge(baseline, latest, current, START, END);

    expect(report.markers.baseline.scan).toBe('absent');
    expect(report.verdict).not.toBe('no-adopter-drift');
  });

  test('no upstream change takes priority over an in-region drift', () => {
    const baseline = ['outside', START, 'region base', END].join('\n');
    const latest = ['outside', START, 'region latest', END].join('\n');
    const current = ['outside', START, 'region drifted', END].join('\n');

    const report = computeRegionMerge(baseline, latest, current, START, END);

    expect(report.verdict).toBe('no-upstream-change');
  });

  test('already at latest: current matches latest, differs from baseline', () => {
    const baseline = ['A', START, 'region base', END].join('\n');
    const latest = ['B', START, 'region latest', END].join('\n');
    const current = ['B', START, 'region current', END].join('\n');

    const report = computeRegionMerge(baseline, latest, current, START, END);

    expect(report.verdict).toBe('already-latest');
  });

  test('a substring-only marker-looking line scans absent, so that side is compared unmasked', () => {
    const baseline = 'plain\n';
    const latest = 'plain\n';
    const current = [
      `Use the \`${START}\` marker to delimit it.`,
      'prose',
    ].join('\n');

    const report = computeRegionMerge(baseline, latest, current, START, END);

    expect(report.markers.current).toEqual({masked: false, scan: 'absent'});
  });

  test('idempotence: repeated invocation on the same inputs is deeply equal', () => {
    const baseline = ['outside', START, 'region base', END].join('\n');
    const latest = ['new outside', START, 'region base', END].join('\n');
    const current = ['outside', START, 'region base', END].join('\n');

    const first = computeRegionMerge(baseline, latest, current, START, END);
    const second = computeRegionMerge(baseline, latest, current, START, END);

    expect(second).toEqual(first);
  });

  test('re-invocation on the post-update tree is stable across repeated calls, even though it differs from the update-time verdict', () => {
    const baseline = ['old outside', START, 'region base', END].join('\n');
    const latest = ['new outside', START, 'region latest', END].join('\n');
    const preUpdateCurrent = ['old outside', START, 'region drifted', END].join(
      '\n'
    );

    const updateTime = computeRegionMerge(
      baseline,
      latest,
      preUpdateCurrent,
      START,
      END
    );
    expect(updateTime.verdict).toBe('no-adopter-drift');

    // Post-update: the working copy now equals the release copy, byte for byte.
    const postUpdateCurrent = latest;

    const firstReinvocation = computeRegionMerge(
      baseline,
      latest,
      postUpdateCurrent,
      START,
      END
    );
    const secondReinvocation = computeRegionMerge(
      baseline,
      latest,
      postUpdateCurrent,
      START,
      END
    );

    // Under the frozen verdict order this is 'already-latest', not
    // 'no-adopter-drift': normalized.current === normalized.latest now takes
    // rule 3 ahead of rule 2. The SPEC's literal wording asks for the same
    // verdict the update returned; that is unsatisfiable by construction once
    // baseline != latest, so the assertable property is stability across
    // repeated re-invocations, not equality with the update-time verdict
    // (README.md C3, AUDIT directive 5).
    expect(firstReinvocation.verdict).toBe('already-latest');
    expect(secondReinvocation.verdict).toBe(firstReinvocation.verdict);
    expect(secondReinvocation).toEqual(firstReinvocation);
  });

  test.each(
    [
      {
        // The baseline region is empty.
        baseline: ['outside', START, END].join('\n'),
        latest: [
          'outside',
          START,
          'line one',
          'line two',
          'line three',
          END,
        ].join('\n'),
        name: 'empty region on one side, populated region on the other: both mask to the same single placeholder line',
      },
      {
        baseline: ['outside', START, 'one line', END].join('\n'),
        latest: ['outside', START, 'one', 'two', 'three', END].join('\n'),
        name: 'different region line counts on both sides mask to byte-identical forms',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {baseline, latest}) => {
    const current = baseline;

    const report = computeRegionMerge(baseline, latest, current, START, END);

    expect(report.normalized.baseline).toBe(report.normalized.latest);
  });
});

type Sandbox = {
  baselinePath: string;
  cleanup: () => void;
  currentPath: string;
  latestPath: string;
  root: string;
  write: (which: 'baseline' | 'current' | 'latest', contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-field-merge-region-'));
  const baselinePath = path.join(root, 'baseline.txt');
  const latestPath = path.join(root, 'latest.txt');
  const currentPath = path.join(root, 'current.txt');

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

const argv = (sandbox: Sandbox): string[] => [
  '--baseline',
  sandbox.baselinePath,
  '--latest',
  sandbox.latestPath,
  '--current',
  sandbox.currentPath,
  '--start-marker',
  START,
  '--end-marker',
  END,
  '--json',
];

describe('update merge-region (run)', () => {
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

  const allSides = {
    baseline: 'baseline\n',
    current: 'current\n',
    latest: 'latest\n',
  };

  test.each(
    (
      [
        {
          argv,
          code: 'region_file_missing',
          // current is never written.
          files: {baseline: 'baseline\n', latest: 'latest\n'},
          name: 'missing --current file exits 1 with region_file_missing',
        },
        {
          argv: (fixture) =>
            argv(fixture).filter(
              (token) => token !== '--current' && token !== fixture.currentPath
            ),
          code: 'invalid_arguments',
          files: allSides,
          name: 'a missing required flag exits 1 with invalid_arguments',
        },
        // A bare VALUE_FLAGS index returns the inherited value for these tokens,
        // which would skip the unknown-flag branch and silently consume the
        // NEXT argv element as the flag's value.
        ...['constructor', 'toString', 'valueOf', '__proto__'].map((token) => ({
          argv: (fixture: Sandbox): string[] => [
            ...argv(fixture),
            token,
            'swallowed',
          ],
          code: 'invalid_arguments',
          files: allSides,
          name: `an unknown flag named after an Object.prototype key (${token}) exits 1 with invalid_arguments`,
        })),
        {
          argv: (fixture) => [
            '--baseline',
            fixture.baselinePath,
            '--latest',
            fixture.latestPath,
            '--current',
            fixture.currentPath,
            '--start-marker',
            '',
            '--end-marker',
            END,
          ],
          code: 'invalid_arguments',
          files: allSides,
          name: 'an empty --start-marker exits 1',
        },
      ] satisfies {
        argv: (sandbox: Sandbox) => string[];
        code: string;
        files: Partial<Record<'baseline' | 'current' | 'latest', string>>;
        name: string;
      }[]
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {argv: buildArgv, code, files}) => {
    for (const [which, contents] of Object.entries(files)) {
      sandbox.write(which as keyof typeof files, contents);
    }

    const exit = run(buildArgv(sandbox));

    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(code);
  });

  test('--help exits 0 and prints the usage banner', () => {
    const exit = run(['--help']);

    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia update merge-region');
  });

  test('--json writes exactly one line of JSON to stdout', () => {
    sandbox.write('baseline', 'plain baseline\n');
    sandbox.write('latest', 'plain latest\n');
    sandbox.write('current', 'plain current\n');

    const exit = run(argv(sandbox));

    expect(exit).toBe(0);
    const lines = stdio.outputs.join('').split('\n').filter(Boolean);
    expect(lines).toHaveLength(1);
    const report = JSON.parse(soleLine(lines)) as RegionMergeReport;
    expect(report.verdict).toBe('conflict');
  });
});
