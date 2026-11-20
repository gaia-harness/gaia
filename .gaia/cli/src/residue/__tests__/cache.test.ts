import {afterEach, describe, expect, test} from 'vitest';
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
import {
  clearCursor,
  emptyAttributionCache,
  readAttributionCache,
  readCursor,
  writeAttributionCache,
  writeCursor,
} from '../cache.js';

const cacheFilePath = (root: string): string =>
  path.join(root, '.gaia', 'local', 'cache', 'residual-attribution.json');

describe('attribution cache', () => {
  const dirs: string[] = [];

  const makeRoot = (): string => {
    const dir = mkdtempSync(path.join(tmpdir(), 'gaia-residue-cache-'));

    dirs.push(dir);

    return dir;
  };

  afterEach(() => {
    for (const dir of dirs.splice(0))
      rmSync(dir, {force: true, recursive: true});
  });

  test.each<{setup: (root: string) => void; title: string}>([
    {
      setup: () => {},
      title: 'a missing cache file reads as empty, no throw',
    },
    {
      setup: (root) => {
        mkdirSync(path.join(root, '.gaia', 'local', 'cache'), {
          recursive: true,
        });
        writeFileSync(cacheFilePath(root), '{"schema":"v2","prs":{"1":', {
          flag: 'w',
        });
      },
      title: 'a corrupt (truncated) cache file reads as empty, no throw',
    },
    {
      // v2 attributions carry a failure_mode cut at the bullet's first line,
      // so a v2 cache must re-attribute rather than serve that text forever.
      setup: (root) => {
        writeAttributionCache(root, {
          ...emptyAttributionCache(),
          high_water_merged_at: '2026-01-01T00:00:00Z',
        });
        writeFileSync(
          cacheFilePath(root),
          readFileSync(cacheFilePath(root), 'utf8').replace(
            '"schema":"v3"',
            '"schema":"v2"'
          )
        );
      },
      title: 'a cache stamped v2 reads as empty',
    },
  ])('$title', ({setup}) => {
    const root = makeRoot();

    setup(root);

    expect(() => readAttributionCache(root)).not.toThrow();
    expect(readAttributionCache(root)).toEqual(emptyAttributionCache());
  });

  test.each([
    {
      cache: {
        ...emptyAttributionCache(),
        high_water_merged_at: '2026-01-01T00:00:00Z',
      },
      title: 'writeAttributionCache then readAttributionCache round-trips',
    },
    {
      cache: emptyAttributionCache(),
      title: 'an unwritten cache directory is created on write',
    },
  ])('$title', ({cache}) => {
    const root = makeRoot();

    writeAttributionCache(root, cache);

    expect(existsSync(cacheFilePath(root))).toBe(true);
    expect(readAttributionCache(root)).toEqual(cache);
  });
});

describe('cursor', () => {
  const dirs: string[] = [];

  const makeRoot = (): string => {
    const dir = mkdtempSync(path.join(tmpdir(), 'gaia-residue-cursor-'));

    dirs.push(dir);

    return dir;
  };

  afterEach(() => {
    for (const dir of dirs.splice(0))
      rmSync(dir, {force: true, recursive: true});
  });

  test('a missing cursor file reads as null, no throw', () => {
    const root = makeRoot();

    expect(readCursor(root)).toBeNull();
  });

  test('writeCursor then readCursor round-trips; clear removes it', () => {
    const root = makeRoot();
    const cursor = {line: 42, path: 'app/x.ts', pr_number: 1234};

    writeCursor(root, cursor);
    expect(readCursor(root)).toEqual(cursor);

    clearCursor(root);
    expect(readCursor(root)).toBeNull();
  });

  test('clearing an already-absent cursor is a no-op, not a throw', () => {
    const root = makeRoot();

    expect(() => clearCursor(root)).not.toThrow();
  });
});
