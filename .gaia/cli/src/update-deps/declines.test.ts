import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {execGaiaGit} from '../util/git-env.js';
import {newMainCheckout} from '../util/main-checkout-fixture.js';
import {
  collectOutstandingGroups,
  collectSnoozedGroups,
  computeActionableCount,
  declinedLedgerPath,
  findActiveDecline,
  isSuppressed,
  loadDeclines,
  MAX_SNOOZE_MS,
  saveDeclines,
  totalCount,
} from './declines.js';
import type {CountablePayload, DeclinedRecord} from './declines.js';

type Sandbox = {cleanup: () => void; root: string};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-declines-'));

  return {
    cleanup: () => rmSync(root, {force: true, recursive: true}),
    root,
  };
};

// A two-group outstanding payload: `react-router` (Wave B, 2 members) and the
// `singleton:left-pad` (Wave A, 1 member). Used across the count tests.
const payload: CountablePayload = {
  wave_a: [
    {
      current: '1.3.0',
      group: 'singleton:left-pad',
      latest: '1.4.0',
      name: 'left-pad',
    },
  ],
  wave_b: [
    {
      group: 'react-router',
      packages: [
        {current: '7.1.0', latest: '7.2.0', name: 'react-router'},
        {current: '7.1.0', latest: '7.2.0', name: '@react-router/serve'},
      ],
    },
  ],
};

const reactRouterTargets = {
  '@react-router/serve': '7.2.0',
  'react-router': '7.2.0',
};

const now = new Date('2026-06-11T18:00:00.000Z');

const declineRecord = (
  overrides: Partial<DeclinedRecord> = {}
): DeclinedRecord => ({
  declined_at: now.toISOString(),
  group: 'react-router',
  targets: reactRouterTargets,
  ...overrides,
});

describe('declines ledger I/O', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('loadDeclines returns empty when the ledger is absent', () => {
    expect(loadDeclines(sandbox.root)).toEqual([]);
  });

  test('saveDeclines then loadDeclines round-trips records', () => {
    const records = [declineRecord()];
    saveDeclines(sandbox.root, records);
    expect(loadDeclines(sandbox.root)).toEqual(records);
  });

  test('saveDeclines writes to .gaia/local/declined-updates.json', () => {
    saveDeclines(sandbox.root, [declineRecord()]);
    const expected = path.join(
      sandbox.root,
      '.gaia',
      'local',
      'declined-updates.json'
    );
    expect(declinedLedgerPath(sandbox.root)).toBe(expected);
    const parsed = JSON.parse(readFileSync(expected, 'utf8')) as unknown;
    expect(parsed).toMatchObject({schema_version: 1});
  });

  test('loadDeclines tolerates malformed JSON and drops bad records', () => {
    const ledger = declinedLedgerPath(sandbox.root);
    saveDeclines(sandbox.root, []); // ensure parent dir exists
    writeFileSync(
      ledger,
      JSON.stringify({
        declined: [
          declineRecord(),
          {group: 'no-targets'},
          {declined_at: now.toISOString(), group: 'x', targets: {a: 1}},
        ],
        schema_version: 1,
      }),
      'utf8'
    );
    // Only the well-formed record survives.
    expect(loadDeclines(sandbox.root)).toEqual([declineRecord()]);
  });
});

describe('declines ledger anchoring', () => {
  let mainRoot: string;

  beforeEach(() => {
    mainRoot = newMainCheckout('gaia-declines-anchor-');
  });

  afterEach(() => {
    rmSync(mainRoot, {force: true, recursive: true});
  });

  const mainLedger = (): string =>
    path.join(mainRoot, '.gaia', 'local', 'declined-updates.json');

  test('a call from a subdirectory writes and reads the root ledger', () => {
    const subdirectory = path.join(mainRoot, 'nested', 'deeper');
    mkdirSync(subdirectory, {recursive: true});

    saveDeclines(subdirectory, [declineRecord()]);

    expect(declinedLedgerPath(subdirectory)).toBe(mainLedger());
    expect(existsSync(mainLedger())).toBe(true);
    expect(existsSync(path.join(subdirectory, '.gaia'))).toBe(false);
    expect(loadDeclines(mainRoot)).toEqual([declineRecord()]);
    expect(loadDeclines(subdirectory)).toEqual([declineRecord()]);
  });

  test('a call from a linked worktree resolves to the main checkout ledger', () => {
    const worktree = path.join(mainRoot, 'linked');
    execGaiaGit(['worktree', 'add', '-q', '-b', 'linked', worktree], mainRoot);

    saveDeclines(worktree, [declineRecord()]);

    expect(declinedLedgerPath(worktree)).toBe(mainLedger());
    expect(existsSync(path.join(worktree, '.gaia'))).toBe(false);
    expect(loadDeclines(mainRoot)).toEqual([declineRecord()]);
  });
});

const windowRecord = declineRecord();
const movedTargets = {...reactRouterTargets, 'react-router': '7.3.0'};

type WindowCase = {
  currentTargets: Record<string, string>;
  isActive: boolean;
  laterBy: number;
  name: string;
};

// Each row asserts both readers of the window, so isSuppressed and
// findActiveDecline cannot disagree on a case.
const assertWindow = ({
  currentTargets,
  isActive,
  laterBy,
}: WindowCase): void => {
  const query = {
    currentTargets,
    declines: [windowRecord],
    group: 'react-router',
    now: new Date(now.getTime() + laterBy),
  };

  expect(isSuppressed(query)).toBe(isActive);
  expect(findActiveDecline(query)).toBe(isActive ? windowRecord : undefined);
};

const titled = (rows: WindowCase[]): (readonly [string, WindowCase])[] =>
  rows.map((row) => [row.name, row] as const);

describe('isSuppressed', () => {
  test.each(
    titled([
      {
        currentTargets: reactRouterTargets,
        isActive: true,
        laterBy: 0,
        name: 'matches on equal group + targets inside the 14-day window',
      },
      {
        currentTargets: movedTargets,
        isActive: false,
        laterBy: 0,
        name: 'does not match when a target version moved',
      },
      {
        currentTargets: {...reactRouterTargets, '@react-router/dev': '7.2.0'},
        isActive: false,
        laterBy: 0,
        name: 'does not match when a new sibling joins the group',
      },
      {
        currentTargets: reactRouterTargets,
        isActive: true,
        laterBy: MAX_SNOOZE_MS - 24 * 3600 * 1000,
        name: 'still suppressed one day before the 14-day cap',
      },
      {
        currentTargets: reactRouterTargets,
        isActive: false,
        laterBy: MAX_SNOOZE_MS,
        name: 'resurfaces once the 14-day cap elapses',
      },
    ])
  )('%s', (_name, row) => {
    expect.hasAssertions();
    assertWindow(row);
  });
});

describe('findActiveDecline', () => {
  test.each(
    titled([
      {
        currentTargets: reactRouterTargets,
        isActive: true,
        laterBy: 0,
        name: 'returns the matching record inside the window',
      },
      {
        currentTargets: movedTargets,
        isActive: false,
        laterBy: 0,
        name: 'returns undefined when nothing matches',
      },
      {
        currentTargets: reactRouterTargets,
        isActive: false,
        laterBy: MAX_SNOOZE_MS,
        name: 'returns undefined once the cap elapses',
      },
    ])
  )('%s', (_name, row) => {
    expect.hasAssertions();
    assertWindow(row);
  });
});

describe('collectSnoozedGroups', () => {
  test('surfaces an actively-snoozed group with resurface metadata', () => {
    expect(collectSnoozedGroups(payload, [declineRecord()], now)).toEqual([
      {
        group: 'react-router',
        resurfaces_at: new Date(now.getTime() + MAX_SNOOZE_MS).toISOString(),
        snoozed_at: now.toISOString(),
        targets: reactRouterTargets,
      },
    ]);
  });

  test.each(
    [
      {
        declines: [declineRecord()],
        laterBy: MAX_SNOOZE_MS,
        name: 'omits a group whose decline aged out of the window',
      },
      {
        declines: [
          declineRecord({
            targets: {...reactRouterTargets, 'react-router': '7.3.0'},
          }),
        ],
        laterBy: 0,
        name: 'omits a group whose targets no longer match the offer',
      },
      {
        declines: [],
        laterBy: 0,
        name: 'returns empty when the ledger is empty',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {declines, laterBy}) => {
    expect(
      collectSnoozedGroups(payload, declines, new Date(now.getTime() + laterBy))
    ).toEqual([]);
  });

  test('sorts multiple snoozed groups by group id', () => {
    const multi: CountablePayload = {
      wave_a: [
        {
          current: '1.3.0',
          group: 'singleton:left-pad',
          latest: '1.4.0',
          name: 'left-pad',
        },
      ],
      wave_b: payload.wave_b,
    };
    const leftPad = declineRecord({
      group: 'singleton:left-pad',
      targets: {'left-pad': '1.4.0'},
    });
    const result = collectSnoozedGroups(multi, [declineRecord(), leftPad], now);
    expect(result.map((entry) => entry.group)).toEqual([
      'react-router',
      'singleton:left-pad',
    ]);
  });
});

describe('count helpers', () => {
  test('totalCount counts every Wave A and Wave B package', () => {
    expect(totalCount(payload)).toBe(3);
  });

  test('computeActionableCount equals totalCount when nothing is declined', () => {
    expect(computeActionableCount(payload, [], now)).toBe(3);
  });

  test('computeActionableCount subtracts a suppressed group', () => {
    // react-router (2 packages) suppressed → only left-pad remains.
    expect(computeActionableCount(payload, [declineRecord()], now)).toBe(1);
  });

  test('an aged-out decline no longer suppresses', () => {
    const later = new Date(now.getTime() + MAX_SNOOZE_MS);
    expect(computeActionableCount(payload, [declineRecord()], later)).toBe(3);
  });

  test('collectOutstandingGroups aggregates Wave A rows and Wave B packages', () => {
    const groups = collectOutstandingGroups(payload);
    expect(groups.get('react-router')).toEqual(reactRouterTargets);
    expect(groups.get('singleton:left-pad')).toEqual({'left-pad': '1.4.0'});
  });

  test('a pulled-along up-to-date sibling is not counted', () => {
    // @types/react is current === latest (a sibling dragged in by the group);
    // it must not inflate the count or appear in the group targets.
    const withSibling: CountablePayload = {
      wave_a: [],
      wave_b: [
        {
          group: 'react',
          packages: [
            {current: '18.0.0', latest: '19.0.0', name: 'react'},
            {current: '19.0.0', latest: '19.0.0', name: '@types/react'},
          ],
        },
      ],
    };
    expect(totalCount(withSibling)).toBe(1);
    expect(collectOutstandingGroups(withSibling).get('react')).toEqual({
      react: '19.0.0',
    });
  });

  test.each([
    ['app entry first', ['2.1.0', '2.3.0']],
    ['member entry first', ['2.3.0', '2.1.0']],
  ])(
    'a name outstanding in two workspaces records the higher latest (%s)',
    (_label, latests) => {
      const shared: CountablePayload = {
        wave_a: latests.map((latest) => ({
          current: '2.0.0',
          group: 'singleton:zod',
          latest,
          name: 'zod',
        })),
        wave_b: [],
      };

      expect(collectOutstandingGroups(shared).get('singleton:zod')).toEqual({
        zod: '2.3.0',
      });
      expect(totalCount(shared)).toBe(1);
    }
  );
});
