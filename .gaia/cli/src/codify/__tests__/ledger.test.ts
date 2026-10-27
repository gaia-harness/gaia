import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../../exit.js';
import {declineLedgerPath} from '../../schemas/decline-ledger.js';
import {reviewSnapshotPath} from '../../schemas/review-snapshot.js';
import {run} from '../ledger.js';
import {TALLY_SCHEMA_VERSION} from '../material-rise.js';

type Sandbox = {
  cleanup: () => void;
  ledgerPath: string;
  root: string;
  storePath: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-codify-ledger-'));
  // The handler resolves the repository root, so we need a real git repo.
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    ledgerPath: declineLedgerPath(root),
    root,
    storePath: path.join(root, '.gaia', 'codify-declines'),
  };
};

const writeLegacyLedger = (ledgerPath: string, fixture: unknown): void => {
  mkdirSync(path.dirname(ledgerPath), {recursive: true});
  writeFileSync(ledgerPath, JSON.stringify(fixture), 'utf8');
};

const captureStdio = () => {
  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      err.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    err,
    out,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const FIXED_NOW = new Date('2026-06-05T14:32:00.000Z');
const DAY_MS = 86_400_000;

const recordArgs = (findingClass: string, prCount = 4, audited = 40) => [
  'record',
  '--finding-class',
  findingClass,
  '--pr-count',
  String(prCount),
  '--audited-pr-count',
  String(audited),
];

const legacyEntry = (findingClass: string, declinedAt: string) => ({
  declined_at: declinedAt,
  declined_at_audited_pr_count: 400,
  declined_at_pr_count: 7,
  finding_class: findingClass,
  tally_schema_version: TALLY_SCHEMA_VERSION,
});

describe('codify-ledger', () => {
  let sandbox: Sandbox;
  let io: ReturnType<typeof captureStdio>;

  const storeFiles = (): string[] =>
    existsSync(sandbox.storePath) ? readdirSync(sandbox.storePath) : [];

  const listOutput = () => {
    io.out.length = 0;
    const code = run(['list'], {cwd: sandbox.root, now: () => FIXED_NOW});

    return {code, json: JSON.parse(io.out.join('')) as Record<string, any>};
  };

  const recordAt = (daysOld: number): void => {
    run(recordArgs(`rule/age-${daysOld}`), {
      cwd: sandbox.root,
      now: () => new Date(FIXED_NOW.getTime() - daysOld * DAY_MS),
    });
    io.out.length = 0;
  };

  beforeEach(() => {
    sandbox = setupSandbox();
    io = captureStdio();
  });

  afterEach(() => {
    io.restore();
    sandbox.cleanup();
  });

  describe('record', () => {
    test('writes exactly one committed file with the decline fields and prints its path', () => {
      writeLegacyLedger(sandbox.ledgerPath, {
        declines: [legacyEntry('other/class', FIXED_NOW.toISOString())],
        version: 2,
      });

      const code = run(recordArgs('rule/x'), {
        cwd: sandbox.root,
        now: () => FIXED_NOW,
      });

      expect(code).toBe(EXIT_CODES.OK);

      const files = storeFiles();
      expect(files).toHaveLength(1);
      expect(io.out.join('')).toBe(`.gaia/codify-declines/${files[0]}\n`);
      expect(
        JSON.parse(
          readFileSync(path.join(sandbox.storePath, files[0] ?? ''), 'utf8')
        )
      ).toEqual({
        declined_at: '2026-06-05T14:32:00.000Z',
        declined_at_audited_pr_count: 40,
        declined_at_pr_count: 4,
        finding_class: 'rule/x',
        format_version: 1,
        tally_schema_version: TALLY_SCHEMA_VERSION,
      });
    });

    test('leaves the legacy ledger byte-identical', () => {
      writeLegacyLedger(sandbox.ledgerPath, {
        declines: [legacyEntry('other/class', FIXED_NOW.toISOString())],
        version: 2,
      });
      const before = readFileSync(sandbox.ledgerPath);

      run(recordArgs('rule/x'), {cwd: sandbox.root, now: () => FIXED_NOW});

      expect(readFileSync(sandbox.ledgerPath).equals(before)).toBe(true);
    });

    test('creates no legacy ledger when none existed', () => {
      run(recordArgs('rule/x'), {cwd: sandbox.root, now: () => FIXED_NOW});

      expect(existsSync(sandbox.ledgerPath)).toBe(false);
    });

    test('two records of one class at one instant make two files, one governing', () => {
      const options = {cwd: sandbox.root, now: () => FIXED_NOW};
      run(recordArgs('rule/x'), options);
      run(recordArgs('rule/x', 5), options);

      expect(storeFiles()).toHaveLength(2);

      const {json} = listOutput();
      expect(json.committed).toHaveLength(2);
      expect(
        json.committed.filter((entry: {governing: boolean}) => entry.governing)
      ).toHaveLength(1);
    });

    test('exits with a structured error when the store path is a regular file', () => {
      mkdirSync(path.join(sandbox.root, '.gaia'), {recursive: true});
      writeFileSync(sandbox.storePath, 'not a folder', 'utf8');

      const code = run(recordArgs('rule/x'), {
        cwd: sandbox.root,
        now: () => FIXED_NOW,
      });

      expect(code).toBe(EXIT_CODES.STORAGE_INACCESSIBLE);
      expect(io.err.join('')).toContain('decline_write_failed');
    });

    test.each([
      [
        '--finding-class',
        ['record', '--pr-count', '7', '--audited-pr-count', '4'],
      ],
      [
        '--pr-count',
        ['record', '--finding-class', 'x', '--audited-pr-count', '4'],
      ],
      [
        '--audited-pr-count',
        ['record', '--finding-class', 'x', '--pr-count', '1'],
      ],
    ])('exits 1 and writes nothing when %s is missing', (_flag, argv) => {
      const code = run(argv, {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      expect(storeFiles()).toEqual([]);
    });
  });

  describe('list', () => {
    test('prints empty sources on a fresh repo', () => {
      const {code, json} = listOutput();

      expect(code).toBe(EXIT_CODES.OK);
      expect(json).toEqual({
        committed: [],
        legacy: [],
        legacy_error: null,
        skipped: [],
      });
    });

    test('prints a committed file and a legacy entry, each with its lapsed flag', () => {
      run(recordArgs('rule/x'), {cwd: sandbox.root, now: () => FIXED_NOW});
      writeLegacyLedger(sandbox.ledgerPath, {
        declines: [
          legacyEntry(
            'old/class',
            new Date(FIXED_NOW.getTime() - 100 * DAY_MS).toISOString()
          ),
        ],
        version: 2,
      });

      const {code, json} = listOutput();

      expect(code).toBe(EXIT_CODES.OK);
      expect(json.committed).toHaveLength(1);
      expect(json.committed[0]).toMatchObject({
        finding_class: 'rule/x',
        governing: true,
        lapsed: false,
      });
      expect(json.legacy).toHaveLength(1);
      expect(json.legacy[0]).toMatchObject({
        finding_class: 'old/class',
        lapsed: true,
      });
      expect(json.legacy_error).toBeNull();
    });

    test('reports a malformed legacy ledger as data and still exits 0', () => {
      run(recordArgs('rule/x'), {cwd: sandbox.root, now: () => FIXED_NOW});
      mkdirSync(path.dirname(sandbox.ledgerPath), {recursive: true});
      writeFileSync(sandbox.ledgerPath, '{ not valid json', 'utf8');

      const {code, json} = listOutput();

      expect(code).toBe(EXIT_CODES.OK);
      expect(typeof json.legacy_error).toBe('string');
      expect(json.legacy_error.length).toBeGreaterThan(0);
      expect(json.legacy).toEqual([]);
      expect(json.committed).toHaveLength(1);
    });

    test('rejects an argument', () => {
      expect(run(['list', 'extra'], {cwd: sandbox.root})).toBe(
        EXIT_CODES.UNKNOWN_SUBCOMMAND
      );
    });
  });

  describe('lapsed', () => {
    test('prints only the path of a file older than the window', () => {
      recordAt(91);
      recordAt(10);

      const code = run(['lapsed'], {cwd: sandbox.root, now: () => FIXED_NOW});

      expect(code).toBe(EXIT_CODES.OK);

      const lines = io.out.join('').split('\n').filter(Boolean);
      expect(lines).toHaveLength(1);
      expect(lines[0]).toContain('rule-age-91-');
    });

    test('prints nothing when none is lapsed', () => {
      recordAt(10);

      const code = run(['lapsed'], {cwd: sandbox.root, now: () => FIXED_NOW});

      expect(code).toBe(EXIT_CODES.OK);
      expect(io.out.join('')).toBe('');
    });

    test('rejects an argument', () => {
      expect(run(['lapsed', 'extra'], {cwd: sandbox.root})).toBe(
        EXIT_CODES.UNKNOWN_SUBCOMMAND
      );
    });
  });

  describe('removed verbs', () => {
    test('prune is an unknown subcommand and writes nothing', () => {
      const code = run(['prune', '--window-classes', ''], {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      expect(io.err.join('')).toContain('unknown_subcommand');
      expect(existsSync(sandbox.ledgerPath)).toBe(false);
      expect(storeFiles()).toEqual([]);
    });

    test('is-suppressed is an unknown subcommand', () => {
      const code = run(['is-suppressed', '--finding-class', 'x'], {
        cwd: sandbox.root,
      });

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      expect(io.err.join('')).toContain('unknown_subcommand');
    });
  });

  describe('snapshot dispatch', () => {
    test('record dispatches to the review-snapshot verb', () => {
      const tallyPath = path.join(sandbox.root, 'tally.json');
      writeFileSync(
        tallyPath,
        JSON.stringify({
          audited_pr_count: 400,
          class_inventory: [
            {distinct_pr_count: 40, finding_class: 'holistic/a'},
          ],
          gh_ok: true,
          tally_schema_version: TALLY_SCHEMA_VERSION,
          unclassified_window_count: null,
          window_days: 90,
        }),
        'utf8'
      );

      const recordCode = run(
        ['snapshot', 'record', '--tally-file', 'tally.json'],
        {cwd: sandbox.root}
      );
      expect(recordCode).toBe(EXIT_CODES.OK);
      expect(existsSync(reviewSnapshotPath(sandbox.root))).toBe(true);
    });
  });

  describe('unknown subcommand', () => {
    test('exits non-zero', () => {
      expect(run(['frobnicate'], {cwd: sandbox.root})).not.toBe(EXIT_CODES.OK);
    });
  });
});
