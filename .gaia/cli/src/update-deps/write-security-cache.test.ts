import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {run} from './write-security-cache.js';

const NOW = new Date('2026-10-04T12:00:00Z');
const NOW_SECONDS = Math.floor(NOW.getTime() / 1000);

let root: string;
let cacheDirectory: string;
let cacheFile: string;
let lockDirectory: string;
let outputs: string[];

beforeEach(() => {
  root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-cache-')));
  cacheDirectory = path.join(root, '.gaia/local/cache/shared');
  cacheFile = path.join(cacheDirectory, 'update-check.json');
  lockDirectory = path.join(cacheDirectory, '.update-check.lock');
  mkdirSync(cacheDirectory, {recursive: true});
  outputs = [];
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    outputs.push(String(chunk));

    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
});

afterEach(() => {
  vi.restoreAllMocks();
  rmSync(root, {force: true, recursive: true});
});

const fullCache = (): Record<string, unknown> => ({
  checkedAt: 1,
  cleanseMemoryBaseline: {count: 3, hash: 'abc'},
  codifyNudgeReason: 'recurring',
  gaiaCurrent: '1.6.1',
  outdatedCount: 4,
  residueCandidateCount: 6,
  securityCount: 2,
  securitySource: 'pnpm-audit',
  securityUnavailableReason: 'forbidden',
  unknownFutureKey: {nested: [1, 2]},
});

const writeCache = (value: Record<string, unknown>): string => {
  const text = `${JSON.stringify(value)}\n`;

  writeFileSync(cacheFile, text);

  return text;
};

const readCache = (): Record<string, unknown> =>
  JSON.parse(readFileSync(cacheFile, 'utf8')) as Record<string, unknown>;

const call = (argv: string[], lockWaitMs = 200): number =>
  run(argv, {
    cwd: root,
    lockWaitMs,
    now: () => NOW,
    resolveMainRoot: () => root,
  });

const result = (): Record<string, unknown> =>
  JSON.parse(outputs.join('')) as Record<string, unknown>;

describe('write-security-cache writes', () => {
  test('changes only the security fields and checkedAt', () => {
    const before = fullCache();

    writeCache(before);

    expect(call(['--count', '1', '--source', 'dependabot'])).toBe(
      EXIT_CODES.OK
    );
    expect(result()).toStrictEqual({written: true});
    expect(readCache()).toStrictEqual({
      ...before,
      checkedAt: NOW_SECONDS,
      securityCount: 1,
      securitySource: 'dependabot',
      securityUnavailableReason: '',
    });
  });

  test('records comma-joined reason tokens for the fallback source', () => {
    writeCache(fullCache());

    call([
      '--count',
      '0',
      '--source',
      'pnpm-audit',
      '--reason',
      'gh-missing,forbidden',
    ]);

    expect(readCache().securityCount).toBe(0);
    expect(readCache().securityUnavailableReason).toBe('gh-missing,forbidden');
  });

  test('no cache file is a no-op that creates nothing', () => {
    expect(call(['--count', '1', '--source', 'dependabot'])).toBe(
      EXIT_CODES.OK
    );
    expect(result()).toStrictEqual({reason: 'no-cache', written: false});
    expect(existsSync(cacheFile)).toBe(false);
    expect(existsSync(lockDirectory)).toBe(false);
  });

  test('a run that took the lock removes it afterwards', () => {
    writeCache(fullCache());
    call(['--count', '1', '--source', 'dependabot']);

    expect(existsSync(lockDirectory)).toBe(false);
  });
});

describe('write-security-cache refusals leave the cache byte-identical', () => {
  const fullCacheText = `${JSON.stringify(fullCache())}\n`;
  const validArguments = ['--count', '1', '--source', 'dependabot'];
  const usageError = (
    label: string,
    argv: string[]
  ): {
    argv: string[];
    cacheText: string;
    exit: number;
    name: string;
    reason: string;
  } => ({
    argv,
    cacheText: fullCacheText,
    exit: EXIT_CODES.INVALID_ARGUMENTS,
    name: `${label} exits 2`,
    reason: 'invalid-arguments',
  });

  test.each(
    [
      usageError('--source unavailable', [
        '--count',
        '1',
        '--source',
        'unavailable',
      ]),
      usageError('--count -1', ['--count', '-1', '--source', 'dependabot']),
      usageError('--count 1.5', ['--count', '1.5', '--source', 'dependabot']),
      usageError('--count null with dependabot', [
        '--count',
        'null',
        '--source',
        'dependabot',
      ]),
      usageError('--count null with a reason', [
        '--count',
        'null',
        '--source',
        'pnpm-audit',
        '--reason',
        'forbidden',
      ]),
      usageError('--reason not-a-token', [
        '--count',
        '1',
        '--source',
        'dependabot',
        '--reason',
        'not-a-token',
      ]),
      usageError('an unknown flag', [...validArguments, '--x', 'y']),
      usageError('a missing --count', ['--source', 'dependabot']),
      {
        argv: validArguments,
        cacheText: '{"checkedAt": 1, oops',
        exit: 1,
        name: 'an unparsable cache is refused and left byte-identical',
        reason: 'unreadable-cache',
      },
      {
        argv: validArguments,
        cacheText: '[1,2]',
        exit: 1,
        name: 'a cache holding an array is unreadable, not overwritten',
        reason: 'unreadable-cache',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {argv, cacheText, exit, reason}) => {
    writeFileSync(cacheFile, cacheText);

    expect(call(argv)).toBe(exit);
    expect(result()).toStrictEqual({reason, written: false});
    expect(readFileSync(cacheFile, 'utf8')).toBe(cacheText);
    expect(existsSync(lockDirectory)).toBe(false);
  });
});

describe('write-security-cache lock', () => {
  test('a lock held by another pid yields lock-held, is never removed, and the write succeeds once it clears', () => {
    const before = writeCache(fullCache());

    mkdirSync(lockDirectory);
    writeFileSync(path.join(lockDirectory, 'owner'), `${process.ppid}\n`);

    expect(call(['--count', '1', '--source', 'dependabot'])).toBe(
      EXIT_CODES.OK
    );
    expect(result()).toStrictEqual({reason: 'lock-held', written: false});
    expect(readFileSync(cacheFile, 'utf8')).toBe(before);
    expect(readFileSync(path.join(lockDirectory, 'owner'), 'utf8').trim()).toBe(
      String(process.ppid)
    );

    rmSync(lockDirectory, {recursive: true});
    outputs.length = 0;

    expect(call(['--count', '1', '--source', 'dependabot'])).toBe(
      EXIT_CODES.OK
    );
    expect(result()).toStrictEqual({written: true});
  });
});

describe('write-security-cache help', () => {
  test('--help prints usage naming the verb and exits 0', () => {
    expect(call(['--help'])).toBe(EXIT_CODES.OK);
    expect(outputs.join('')).toContain(
      'Usage: gaia update-deps write-security-cache'
    );
  });
});
