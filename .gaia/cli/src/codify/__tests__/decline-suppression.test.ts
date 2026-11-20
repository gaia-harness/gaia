import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import type * as NodeFs from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {DECLINE_STORE_RELATIVE_PATH} from '../../schemas/decline-file.js';
import {declineLedgerPath} from '../../schemas/decline-ledger.js';
import {loadDeclineSources} from '../decline-suppression.js';
import {TALLY_SCHEMA_VERSION} from '../material-rise.js';
import {WINDOW_DAYS} from '../window.js';

const fsSpies = vi.hoisted(() => ({
  readdirSync: vi.fn(),
  readFileSync: vi.fn(),
}));

vi.mock('node:fs', async (importOriginal) => {
  const actual = await importOriginal<typeof NodeFs>();

  fsSpies.readFileSync.mockImplementation(actual.readFileSync);
  fsSpies.readdirSync.mockImplementation(actual.readdirSync);

  return {
    ...actual,
    readdirSync: fsSpies.readdirSync,
    readFileSync: fsSpies.readFileSync,
  };
});

const DAY_MS = 86_400_000;
const NOW = new Date('2026-10-27T12:00:00.000Z');
const LEGACY_PATH = '.gaia/local/codify/declines.json';

let root: string;
let fileCounter = 0;

const daysAgo = (days: number, extraMs = 0): string =>
  new Date(NOW.getTime() - days * DAY_MS - extraMs).toISOString();

const legacyEntry = (findingClass: string, declinedAt: string, count = 4) => ({
  declined_at: declinedAt,
  declined_at_audited_pr_count: 394,
  declined_at_pr_count: count,
  finding_class: findingClass,
  tally_schema_version: TALLY_SCHEMA_VERSION,
});

const entry = (
  findingClass: string,
  declinedAt: string,
  count = 4,
  schemaVersion = TALLY_SCHEMA_VERSION
) => ({
  ...legacyEntry(findingClass, declinedAt, count),
  format_version: 1,
  tally_schema_version: schemaVersion,
});

const putCommitted = (content: unknown): void => {
  const folder = path.join(root, ...DECLINE_STORE_RELATIVE_PATH.split('/'));

  mkdirSync(folder, {recursive: true});
  fileCounter += 1;
  writeFileSync(
    path.join(folder, `f-${fileCounter}.json`),
    JSON.stringify(content)
  );
};

const putLegacy = (content: unknown): void => {
  const target = declineLedgerPath(root);

  mkdirSync(path.dirname(target), {recursive: true});
  writeFileSync(
    target,
    typeof content === 'string' ? content : JSON.stringify(content)
  );
};

const load = () =>
  loadDeclineSources({now: NOW, repoRoot: root, windowDays: WINDOW_DAYS});

beforeEach(() => {
  root = mkdtempSync(path.join(tmpdir(), 'decline-suppression-'));
  fileCounter = 0;
});

afterEach(() => {
  rmSync(root, {force: true, recursive: true});
});

const resurface = (reason: string) => ({reason, status: 'resurface'});

describe('committed declines', () => {
  const committedSuppressed = {source: 'committed', status: 'suppressed'};

  test.each([
    {
      checks: [
        ['rule/a', 5, committedSuppressed],
        ['rule/a', 12, resurface('material_rise')],
        ['rule/other', 5, resurface('no_decline')],
      ],
      declines: [entry('rule/a', daysAgo(1))],
      name: 'suppress below a material rise and resurface at one',
    },
    {
      checks: [['rule/a', 4, resurface('schema_version_mismatch')]],
      declines: [entry('rule/a', daysAgo(1), 4, TALLY_SCHEMA_VERSION - 1)],
      name: 'a different tally schema version resurfaces below a rise',
    },
    {
      checks: [
        ['rule/live', 4, committedSuppressed],
        ['rule/old', 4, resurface('lapsed')],
      ],
      declines: [
        entry('rule/live', daysAgo(WINDOW_DAYS)),
        entry('rule/old', daysAgo(WINDOW_DAYS, 1)),
      ],
      name: 'exactly one window old is live, one millisecond older lapses',
    },
  ] as {
    checks: [string, number, unknown][];
    declines: unknown[];
    name: string;
  }[])('$name', ({checks, declines}) => {
    for (const decline of declines) {
      putCommitted(decline);
    }

    const {check} = load();

    for (const [findingClass, prCount, expected] of checks) {
      expect(check(findingClass, prCount, 394)).toEqual(expected);
    }
  });

  test('a skipped file is reported by relative path and suppresses nothing', () => {
    putCommitted({...entry('rule/a', daysAgo(1)), format_version: 9});

    const {check, reports} = load();

    expect(reports).toHaveLength(1);
    expect(reports[0]).toMatchObject({
      code: 'skipped_decline_file',
      path: `${DECLINE_STORE_RELATIVE_PATH}/f-1.json`,
    });
    expect(check('rule/a', 4, 394).status).toBe('resurface');
  });
});

describe('legacy ledger', () => {
  test('a live legacy entry suppresses with source legacy', () => {
    putLegacy({declines: [legacyEntry('rule/a', daysAgo(5))], version: 2});

    expect(load().check('rule/a', 4, 394)).toEqual({
      source: 'legacy',
      status: 'suppressed',
    });
  });

  test('a lapsed legacy entry resurfaces and the file is left untouched', () => {
    putLegacy({
      declines: [legacyEntry('rule/a', daysAgo(WINDOW_DAYS, 1))],
      version: 2,
    });

    const target = declineLedgerPath(root);
    const before = readFileSync(target);
    const modifiedBefore = statSync(target).mtimeMs;

    expect(load().check('rule/a', 4, 394)).toEqual({
      reason: 'lapsed',
      status: 'resurface',
    });
    expect(readFileSync(target).equals(before)).toBe(true);
    expect(statSync(target).mtimeMs).toBe(modifiedBefore);
  });

  test('no legacy file means no report and no throw', () => {
    putCommitted(entry('rule/a', daysAgo(1)));

    expect(load().reports).toEqual([]);
  });

  test.each([
    ['invalid JSON', '{nope'],
    [
      'version 1',
      {
        declines: [legacyEntry('rule/legacy-only', daysAgo(1))],
        version: 1,
      },
    ],
  ])(
    'a malformed ledger (%s) fails open with one report',
    (_label, content) => {
      putLegacy(content);
      putCommitted(entry('rule/committed', daysAgo(1)));

      const {check, reports} = load();

      expect(reports).toHaveLength(1);
      expect(reports[0]).toMatchObject({
        code: 'malformed_decline_ledger',
        path: LEGACY_PATH,
      });
      expect(check('rule/legacy-only', 4, 394).status).toBe('resurface');
      expect(check('rule/committed', 4, 394).status).toBe('suppressed');
    }
  );
});

describe('both sources', () => {
  test.each([
    {
      committed: entry('rule/a', daysAgo(1), 10),
      expected: {source: 'committed', status: 'suppressed'},
      legacy: legacyEntry('rule/a', daysAgo(2), 4),
      name: 'committed suppresses while the legacy entry rose materially',
      prCount: 10,
    },
    {
      committed: entry('rule/a', daysAgo(WINDOW_DAYS, 1)),
      expected: {source: 'legacy', status: 'suppressed'},
      legacy: legacyEntry('rule/a', daysAgo(2)),
      name: 'a lapsed committed decline yields to a live legacy one',
      prCount: 4,
    },
    {
      committed: entry('rule/a', daysAgo(WINDOW_DAYS, 1)),
      expected: {reason: 'lapsed', status: 'resurface'},
      legacy: legacyEntry('rule/a', daysAgo(2), 1),
      name: 'both resurfacing resurfaces with the committed reason',
      prCount: 20,
    },
  ])('$name', ({committed, expected, legacy, prCount}) => {
    putCommitted(committed);
    putLegacy({declines: [legacy], version: 2});

    expect(load().check('rule/a', prCount, 394)).toEqual(expected);
  });
});

describe('load once', () => {
  test('the folder and the ledger are each read once however many classes are checked', () => {
    putCommitted(entry('rule/a', daysAgo(1)));
    putLegacy({declines: [legacyEntry('rule/b', daysAgo(1))], version: 2});
    fsSpies.readdirSync.mockClear();
    fsSpies.readFileSync.mockClear();

    const {check} = load();

    check('rule/a', 4, 394);
    check('rule/b', 4, 394);
    check('rule/c', 4, 394);

    const folderReads = fsSpies.readdirSync.mock.calls.filter(([target]) =>
      String(target).endsWith('codify-declines')
    );
    const ledgerReads = fsSpies.readFileSync.mock.calls.filter(([target]) =>
      String(target).endsWith('declines.json')
    );

    expect(folderReads).toHaveLength(1);
    expect(ledgerReads).toHaveLength(1);
  });
});
