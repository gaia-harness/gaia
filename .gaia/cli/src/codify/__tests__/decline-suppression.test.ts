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

describe('committed declines', () => {
  test('suppress below a material rise and resurface at one', () => {
    putCommitted(entry('rule/a', daysAgo(1)));

    const {check} = load();

    expect(check('rule/a', 5, 394)).toEqual({
      source: 'committed',
      status: 'suppressed',
    });
    expect(check('rule/a', 12, 394)).toEqual({
      reason: 'material_rise',
      status: 'resurface',
    });
    expect(check('rule/other', 5, 394)).toEqual({
      reason: 'no_decline',
      status: 'resurface',
    });
  });

  test('a different tally schema version resurfaces below a rise', () => {
    putCommitted(entry('rule/a', daysAgo(1), 4, TALLY_SCHEMA_VERSION - 1));

    expect(load().check('rule/a', 4, 394)).toEqual({
      reason: 'schema_version_mismatch',
      status: 'resurface',
    });
  });

  test('exactly one window old is live, one millisecond older lapses', () => {
    putCommitted(entry('rule/live', daysAgo(WINDOW_DAYS)));
    putCommitted(entry('rule/old', daysAgo(WINDOW_DAYS, 1)));

    const {check} = load();

    expect(check('rule/live', 4, 394).status).toBe('suppressed');
    expect(check('rule/old', 4, 394)).toEqual({
      reason: 'lapsed',
      status: 'resurface',
    });
  });

  test('a 60-day-old decline still suppresses', () => {
    putCommitted(entry('rule/a', daysAgo(60)));

    expect(load().check('rule/a', 4, 394).status).toBe('suppressed');
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
  test('committed suppresses while the legacy entry rose materially', () => {
    putCommitted(entry('rule/a', daysAgo(1), 10));
    putLegacy({declines: [legacyEntry('rule/a', daysAgo(2), 4)], version: 2});

    expect(load().check('rule/a', 10, 394)).toEqual({
      source: 'committed',
      status: 'suppressed',
    });
  });

  test('a lapsed committed decline yields to a live legacy one', () => {
    putCommitted(entry('rule/a', daysAgo(WINDOW_DAYS, 1)));
    putLegacy({declines: [legacyEntry('rule/a', daysAgo(2))], version: 2});

    expect(load().check('rule/a', 4, 394)).toEqual({
      source: 'legacy',
      status: 'suppressed',
    });
  });

  test('both resurfacing resurfaces with the committed reason', () => {
    putCommitted(entry('rule/a', daysAgo(WINDOW_DAYS, 1)));
    putLegacy({declines: [legacyEntry('rule/a', daysAgo(2), 1)], version: 2});

    expect(load().check('rule/a', 20, 394)).toEqual({
      reason: 'lapsed',
      status: 'resurface',
    });
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
