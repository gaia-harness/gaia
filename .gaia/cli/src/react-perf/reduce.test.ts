/**
 * `reduceDump` (the pure algorithm) is asserted directly against the committed
 * fixtures; `run` (the CLI handler) is asserted by capturing stdout/stderr to
 * cover file reading, alien-shape rejection, determinism, and the frame-budget
 * flag. Fixtures live in `test-fixtures/react-perf/`.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {EXIT_CODES} from '../exit.js';
import {
  RawDumpSchema,
  ReducedSummarySchema,
} from '../schemas/react-perf-summary.js';
import type {RawDump} from '../schemas/react-perf-summary.js';
import {reduceDump, run} from './reduce.js';

const FIXTURES = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../test-fixtures/react-perf'
);

const fixturePath = (name: string): string => path.join(FIXTURES, name);

const loadDump = (name: string): RawDump =>
  RawDumpSchema.parse(JSON.parse(readFileSync(fixturePath(name), 'utf8')));

describe('reduceDump (pure algorithm)', () => {
  describe('legacy bippy-renders-dump.json (no planted bug)', () => {
    const summary = reduceDump(loadDump('bippy-renders-dump.json'), {
      frameBudgetMs: 16,
    });

    test('validates against the Contract-B output schema', () => {
      expect(() => ReducedSummarySchema.parse(summary)).not.toThrow();
    });

    test('counts all 248 records', () => {
      expect(summary.totals.records).toBe(248);
      expect(summary.totals.mounts + summary.totals.updates).toBe(248);
    });

    test('filters the known framework cohort out of findings', () => {
      const names = summary.findings.map((finding) => finding.componentName);
      expect(names).not.toContain('RenderedRoute');
      expect(names).not.toContain('Router');
      expect(names).not.toContain('Links');
      expect(summary.totals.frameworkFiltered).toBeGreaterThan(0);
    });

    test.each<{expected: Record<string, unknown>; name: string}>([
      {
        expected: {
          stopSignal: {zeroAppMemoDefeated: true},
          totals: {memoDefeated: 0},
        },
        name: 'reports zero memoDefeated and the matching stop signal',
      },
      {
        expected: {findings: [], stopSignal: {noAppFrameBudgetBreach: true}},
        name: 'has no app component over the default 16ms budget',
      },
      {
        // Legacy meta is {installed, commits, errors} only.
        expected: {
          profilingAvailable: false,
          rendererVersion: null,
          strictModeTimingCaveat: true,
        },
        name: 'defaults the strictMode caveat to true and meta fields from defaults',
      },
      {
        expected: {unknownNameCount: 0},
        name: 'buckets null-name renders into unknownNameCount (zero here)',
      },
    ])('$name', ({expected}) => {
      expect(summary).toMatchObject(expected);
    });
  });

  describe('memo-defeat.json (one planted culprit)', () => {
    const summary = reduceDump(loadDump('memo-defeat.json'), {
      frameBudgetMs: 16,
    });

    test.each<{expected: Record<string, unknown>; name: string}>([
      {
        expected: {
          findings: [
            {
              componentName: 'StatusBadge',
              isMemo: true,
              memoDefeatedCount: 2,
              rank: 1,
              reactDoctorRule: 'jsx-no-new-object-as-prop',
              unstableInputs: ['prop:status'],
            },
          ],
        },
        name: 'produces exactly one memoDefeated finding for StatusBadge, ranked #1',
      },
      {
        expected: {
          stopSignal: {zeroAppMemoDefeated: false},
          totals: {memoDefeated: 2},
        },
        name: 'flips zeroAppMemoDefeated to false',
      },
    ])('$name', ({expected}) => {
      expect(summary).toMatchObject(expected);
    });

    test('does NOT flag the legitimate parent state change (SpikePanel)', () => {
      const names = summary.findings.map((finding) => finding.componentName);
      expect(names).not.toContain('SpikePanel');
    });
  });

  describe('--frame-budget-ms gate', () => {
    test('flips exceedsFrameBudget / noAppFrameBudgetBreach under a low budget', () => {
      const dump = loadDump('bippy-renders-dump.json');
      const tight = reduceDump(dump, {frameBudgetMs: 1});

      expect(tight.stopSignal.noAppFrameBudgetBreach).toBe(false);
      expect(tight.findings.length).toBeGreaterThan(0);
      expect(
        tight.findings.every((finding) => finding.exceedsFrameBudget)
      ).toBe(true);
    });
  });
});

describe('run (CLI handler)', () => {
  let stdout: string;
  let stderr: string;

  beforeEach(() => {
    stdout = '';
    stderr = '';
    vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
      stdout += String(chunk);

      return true;
    });
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
      stderr += String(chunk);

      return true;
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  test.each<{args: string[]; expected: Record<string, unknown>; name: string}>([
    {
      args: [fixturePath('bippy-renders-dump.json')],
      expected: {totals: {records: 248}},
      name: 'prints a schema-valid summary and exits 0',
    },
    {
      args: [fixturePath('bippy-renders-dump.json'), '--frame-budget-ms', '1'],
      expected: {stopSignal: {noAppFrameBudgetBreach: false}},
      name: 'honors --frame-budget-ms when reducing',
    },
  ])('$name', ({args, expected}) => {
    expect(run(args)).toBe(EXIT_CODES.OK);
    expect(stderr).toBe('');
    expect(ReducedSummarySchema.parse(JSON.parse(stdout))).toMatchObject(
      expected
    );
  });

  test('is deterministic: same input yields byte-identical stdout', () => {
    run([fixturePath('bippy-renders-dump.json')]);
    const first = stdout;
    stdout = '';
    run([fixturePath('bippy-renders-dump.json')]);

    expect(stdout).toBe(first);
  });

  test.each<{
    args: string[];
    code: number;
    name: string;
    payloadCode: string;
  }>([
    {
      args: [fixturePath('renders-dump.json')],
      code: EXIT_CODES.PAYLOAD_VALIDATION_FAILED,
      name: 'rejects the alien react-scan dump with a clear error',
      payloadCode: 'invalid_dump',
    },
    {
      args: [fixturePath('does-not-exist.json')],
      code: EXIT_CODES.STORAGE_INACCESSIBLE,
      name: 'errors on a missing input file',
      payloadCode: 'input_unreadable',
    },
    {
      args: [],
      code: EXIT_CODES.UNKNOWN_SUBCOMMAND,
      name: 'errors on a missing path argument',
      payloadCode: 'invalid_arguments',
    },
    {
      args: [
        fixturePath('bippy-renders-dump.json'),
        '--frame-budget-ms',
        'nope',
      ],
      code: EXIT_CODES.UNKNOWN_SUBCOMMAND,
      name: 'errors on a non-numeric --frame-budget-ms',
      payloadCode: 'invalid_arguments',
    },
  ])('$name', ({args, code, payloadCode}) => {
    expect(run(args)).toBe(code);
    expect(stdout).toBe('');
    const payload = JSON.parse(stderr) as {code: string};
    expect(payload.code).toBe(payloadCode);
  });
});
