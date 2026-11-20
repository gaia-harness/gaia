import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  DECLINE_FILE_FORMAT_VERSION,
  DECLINE_STORE_RELATIVE_PATH,
  DeclineFileSchema,
} from '../../schemas/decline-file.js';
import {
  declineFileName,
  governingDeclines,
  isLapsed,
  lapsedDeclinePaths,
  readDeclineStore,
  writeDeclineFile,
} from '../decline-store.js';
import {TALLY_SCHEMA_VERSION} from '../material-rise.js';
import {WINDOW_DAYS} from '../window.js';

const DAY_MS = 86_400_000;
const NOW = new Date('2026-10-27T12:00:00.000Z');

const validFile = {
  declined_at: '2026-10-01T00:00:00.000Z',
  declined_at_audited_pr_count: 394,
  declined_at_pr_count: 4,
  finding_class: 'rule/use-effect-derived-state',
  format_version: 1,
  tally_schema_version: TALLY_SCHEMA_VERSION,
};

let root: string;

const folder = (): string =>
  path.join(root, ...DECLINE_STORE_RELATIVE_PATH.split('/'));

const putFile = (name: string, content: unknown): void => {
  mkdirSync(folder(), {recursive: true});
  writeFileSync(
    path.join(folder(), name),
    typeof content === 'string' ? content : JSON.stringify(content)
  );
};

const relative = (name: string): string =>
  `${DECLINE_STORE_RELATIVE_PATH}/${name}`;

const args = () => ({
  auditedPrCount: 394,
  findingClass: 'rule/x',
  now: NOW,
  prCount: 4,
  repoRoot: root,
});

const read = () => readDeclineStore(root).files;

beforeEach(() => {
  root = mkdtempSync(path.join(tmpdir(), 'decline-store-'));
});

afterEach(() => {
  rmSync(root, {force: true, recursive: true});
});

describe('DeclineFileSchema', () => {
  test('a version-1 object round-trips', () => {
    expect(DECLINE_FILE_FORMAT_VERSION).toBe(1);
    expect(DeclineFileSchema.parse(validFile)).toEqual(validFile);
  });

  test('an unknown extra key still parses', () => {
    expect(
      DeclineFileSchema.safeParse({...validFile, future_field: 'x'}).success
    ).toBe(true);
  });

  test.each([
    ['format_version 2', {...validFile, format_version: 2}],
    [
      'missing format_version',
      Object.fromEntries(
        Object.entries(validFile).filter(([key]) => key !== 'format_version')
      ),
    ],
    [
      'non-UTC declined_at',
      {...validFile, declined_at: '2026-10-01T00:00:00+09:00'},
    ],
    ['negative count', {...validFile, declined_at_pr_count: -1}],
  ])('rejects %s', (_label, input) => {
    expect(DeclineFileSchema.safeParse(input).success).toBe(false);
  });
});

describe('declineFileName', () => {
  const declinedAt = new Date('2026-10-27T14:32:00.123Z');

  test.each([
    ['rule/use-effect-derived-state', 'rule-use-effect-derived-state'],
    ['axe/color-contrast@4', 'axe-color-contrast-4'],
    ['holistic/unclassified', 'holistic-unclassified'],
    ['@@@///', 'class'],
    ['A'.repeat(200), 'a'.repeat(80)],
    // Truncation lands on a dash, which the slug trims.
    [`${'a'.repeat(79)}/b`, 'a'.repeat(79)],
  ])('encodes %s', (findingClass, slug) => {
    const name = declineFileName({
      declinedAt,
      findingClass,
      suffix: 'deadbeef',
    });

    expect(name).toBe(`${slug}-20261027-143200123-deadbeef.json`);
    expect(name).toMatch(/^[a-z0-9]+(-[a-z0-9]+)*\.json$/u);
  });
});

describe('writeDeclineFile', () => {
  test('writes a stamped, format-first file and returns its relative path', () => {
    const {relativePath} = writeDeclineFile(args());

    expect(relativePath.startsWith(`${DECLINE_STORE_RELATIVE_PATH}/`)).toBe(
      true
    );
    expect(relativePath).not.toContain('\\');

    const text = readFileSync(path.join(root, relativePath), 'utf8');

    expect(text.endsWith('\n')).toBe(true);
    expect(text.startsWith('{\n  "format_version": 1,')).toBe(true);
    expect(JSON.parse(text)).toEqual({
      declined_at: NOW.toISOString(),
      declined_at_audited_pr_count: 394,
      declined_at_pr_count: 4,
      finding_class: 'rule/x',
      format_version: 1,
      tally_schema_version: TALLY_SCHEMA_VERSION,
    });
  });

  test('same clock and class produce two distinct files', () => {
    const first = writeDeclineFile(args());
    const second = writeDeclineFile(args());

    expect(first.relativePath).not.toBe(second.relativePath);
    expect(readDeclineStore(root).files).toHaveLength(2);
  });

  test('a colliding suffix throws and leaves the original untouched', () => {
    const first = writeDeclineFile({...args(), randomSuffix: () => 'aaaaaaaa'});
    const target = path.join(root, first.relativePath);
    const before = readFileSync(target);

    expect(() =>
      writeDeclineFile({
        ...args(),
        auditedPrCount: 1,
        prCount: 1,
        randomSuffix: () => 'aaaaaaaa',
      })
    ).toThrow(/EEXIST/u);
    expect(readFileSync(target).equals(before)).toBe(true);
  });
});

describe('readDeclineStore', () => {
  test('reads valid files and reports exactly the unusable ones', () => {
    putFile('a-good.json', validFile);
    putFile('b-broken.json', '{not json');
    putFile('c-future.json', {...validFile, format_version: 9});
    putFile('d-notes.txt', 'ignored');

    const result = readDeclineStore(root);

    expect(result.files.map((file) => file.relativePath)).toEqual([
      relative('a-good.json'),
    ]);
    expect(
      result.skipped
        .map((skip) => skip.relativePath)
        .toSorted((a, b) => a.localeCompare(b))
    ).toEqual([relative('b-broken.json'), relative('c-future.json')]);
    expect(result.skipped.every((skip) => skip.reason.length > 0)).toBe(true);
  });

  test('a missing format_version and a non-object value are skips', () => {
    putFile('a.json', {...validFile, format_version: undefined});
    putFile('b.json', '[1,2]');
    putFile('c.json', 'null');

    const result = readDeclineStore(root);

    expect(result.files).toEqual([]);
    expect(result.skipped).toHaveLength(3);
  });

  test('a missing folder reads empty', () => {
    expect(readDeclineStore(root)).toEqual({files: [], skipped: []});
  });

  test('an unreadable folder is one skip naming the folder', () => {
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    writeFileSync(folder(), 'a file where the folder belongs');

    const result = readDeclineStore(root);

    expect(result.files).toEqual([]);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0]?.relativePath).toBe(DECLINE_STORE_RELATIVE_PATH);
  });
});

describe('governingDeclines', () => {
  test.each([
    {
      files: [
        ['x-1.json', {declined_at: '2026-10-01T00:00:00Z'}],
        ['x-2.json', {declined_at: '2026-10-01T00:00:00.5Z'}],
      ],
      name: 'compares parsed instants, not strings',
      winner: 'x-2.json',
    },
    {
      files: [
        ['x-a.json', {}],
        ['x-b.json', {}],
        ['X-c.json', {}],
      ],
      name: 'a tie goes to the byte-wise last basename',
      winner: 'x-b.json',
    },
    {
      // Unclamped, x-a would win on its later instant; clamped, the two tie
      // and the last basename governs.
      files: [
        ['x-a.json', {declined_at: '2027-01-01T00:00:00Z'}],
        ['x-b.json', {declined_at: NOW.toISOString()}],
      ],
      name: 'a future timestamp does not outrank a file written at now',
      winner: 'x-b.json',
    },
  ] as {
    files: [string, Record<string, string>][];
    name: string;
    winner: string;
  }[])('$name', ({files, winner}) => {
    for (const [fileName, overrides] of files) {
      putFile(fileName, {...validFile, ...overrides});
    }

    expect(
      governingDeclines(read(), NOW).get(validFile.finding_class)?.relativePath
    ).toBe(relative(winner));
  });
});

describe('isLapsed', () => {
  test.each([
    [
      'exactly one window old is live',
      new Date(NOW.getTime() - WINDOW_DAYS * DAY_MS).toISOString(),
      false,
    ],
    [
      'one millisecond older than the window is lapsed',
      new Date(NOW.getTime() - WINDOW_DAYS * DAY_MS - 1).toISOString(),
      true,
    ],
    ['a future-dated file is live', '2099-01-01T00:00:00Z', false],
  ])('%s', (_label, declinedAt, expected) => {
    expect(isLapsed(declinedAt, NOW, WINDOW_DAYS)).toBe(expected);
  });
});

describe('lapsedDeclinePaths', () => {
  test('lists only the lapsed parsed file', () => {
    putFile('a-lapsed.json', {
      ...validFile,
      declined_at: '2026-01-01T00:00:00Z',
    });
    putFile('b-live.json', {...validFile, declined_at: '2026-10-20T00:00:00Z'});
    putFile('c-skipped.json', '{nope');

    expect(
      lapsedDeclinePaths({now: NOW, repoRoot: root, windowDays: WINDOW_DAYS})
    ).toEqual([relative('a-lapsed.json')]);
  });
});
