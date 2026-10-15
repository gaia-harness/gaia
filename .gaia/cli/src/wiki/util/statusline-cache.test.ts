import {afterEach, beforeEach, describe, expect, test} from 'vitest';
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
import {newMainCheckout} from '../../util/main-checkout-fixture.js';
import {
  invalidateStatuslineCache,
  refreshWikiDriftInCache,
} from './statusline-cache.js';

describe('invalidateStatuslineCache', () => {
  let root: string;
  let cacheDirectory: string;
  let cachePath: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-statusline-cache-'));
    execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
    execFileSync('git', ['config', 'user.email', 'test@example.com'], {
      cwd: root,
    });
    execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
    execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});
    execFileSync('git', ['commit', '-q', '--allow-empty', '-m', 'initial'], {
      cwd: root,
    });
    cacheDirectory = path.join(root, '.gaia', 'local', 'cache', 'shared');
    cachePath = path.join(cacheDirectory, 'update-check.json');
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
  });

  const seed = (contents: string): void => {
    mkdirSync(cacheDirectory, {recursive: true});
    writeFileSync(cachePath, contents, 'utf8');
  };

  test('sets checkedAt to 0 and preserves every other key', () => {
    seed(
      JSON.stringify({
        checkedAt: 1_700_000_000,
        latestVersion: '1.2.3',
        residueCandidateCount: 4,
        wikiDriftCount: 31,
      })
    );

    invalidateStatuslineCache(root);

    expect(JSON.parse(readFileSync(cachePath, 'utf8'))).toEqual({
      checkedAt: 0,
      latestVersion: '1.2.3',
      residueCandidateCount: 4,
      wikiDriftCount: 31,
    });
  });

  test('adds checkedAt 0 when the cache object has no checkedAt', () => {
    seed(JSON.stringify({wikiDriftCount: 2}));

    invalidateStatuslineCache(root);

    expect(JSON.parse(readFileSync(cachePath, 'utf8'))).toEqual({
      checkedAt: 0,
      wikiDriftCount: 2,
    });
  });

  test('leaves no temporary file behind', () => {
    seed(JSON.stringify({checkedAt: 5}));

    invalidateStatuslineCache(root);

    expect(readdirSync(cacheDirectory)).toEqual(['update-check.json']);
  });

  test('creates nothing when the cache file is absent', () => {
    invalidateStatuslineCache(root);

    expect(existsSync(path.join(root, '.gaia'))).toBe(false);
  });

  test.each([
    ['unparseable JSON', '{not json'],
    ['a JSON array', '[1, 2]'],
    ['a JSON scalar', '42'],
    ['JSON null', 'null'],
  ])('leaves the file untouched for %s', (_label, contents) => {
    seed(contents);

    expect(() => {
      invalidateStatuslineCache(root);
    }).not.toThrow();
    expect(readFileSync(cachePath, 'utf8')).toBe(contents);
  });

  test('does not throw outside a git repository', () => {
    const outside = mkdtempSync(path.join(tmpdir(), 'gaia-statusline-bare-'));

    try {
      expect(() => {
        invalidateStatuslineCache(outside);
      }).not.toThrow();
    } finally {
      rmSync(outside, {force: true, recursive: true});
    }
  });

  test('from a linked worktree, rewrites the main checkout cache', () => {
    seed(JSON.stringify({checkedAt: 99, wikiDriftCount: 8}));
    const linked = path.join(root, '.claude', 'worktrees', 'linked');
    execFileSync('git', ['worktree', 'add', '-q', '-b', 'linked', linked], {
      cwd: root,
    });

    invalidateStatuslineCache(linked);

    expect(JSON.parse(readFileSync(cachePath, 'utf8'))).toEqual({
      checkedAt: 0,
      wikiDriftCount: 8,
    });
    expect(existsSync(path.join(linked, '.gaia'))).toBe(false);
  });
});

const commit = (cwd: string, subject: string): void => {
  execFileSync('git', ['commit', '-q', '--allow-empty', '-m', subject], {
    cwd,
  });
};

const headOf = (cwd: string): string =>
  execFileSync('git', ['rev-parse', 'HEAD'], {cwd, encoding: 'utf8'}).trim();

describe('refreshWikiDriftInCache', () => {
  let root: string;
  let cacheDirectory: string;
  let cachePath: string;

  const writeState = (sha: string): void => {
    mkdirSync(path.join(root, 'wiki'), {recursive: true});
    writeFileSync(
      path.join(root, 'wiki', '.state.json'),
      JSON.stringify({last_evaluated_sha: sha}),
      'utf8'
    );
  };

  const seed = (contents: string): void => {
    mkdirSync(cacheDirectory, {recursive: true});
    writeFileSync(cachePath, contents, 'utf8');
  };

  beforeEach(() => {
    root = newMainCheckout('gaia-statusline-refresh-');
    cacheDirectory = path.join(root, '.gaia', 'local', 'cache', 'shared');
    cachePath = path.join(cacheDirectory, 'update-check.json');
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
  });

  test('writes the drift and the state sha the refresher writes, keeping every other key', () => {
    const evaluated = headOf(root);
    writeState(evaluated);
    commit(root, 'feat: one');
    commit(root, 'wiki: 2026-10-15 05:32 UTC');
    commit(root, 'feat: two');
    seed(JSON.stringify({checkedAt: 1_700_000_000, wikiDriftCount: 52}));

    expect(refreshWikiDriftInCache(root)).toBe(2);
    expect(JSON.parse(readFileSync(cachePath, 'utf8'))).toEqual({
      checkedAt: 1_700_000_000,
      wikiDriftCount: 2,
      wikiStateSha: evaluated,
    });
  });

  test('a state file at HEAD clears a showing count to 0', () => {
    writeState(headOf(root));
    seed(JSON.stringify({checkedAt: 5, wikiDriftCount: 52}));

    expect(refreshWikiDriftInCache(root)).toBe(0);
    expect(JSON.parse(readFileSync(cachePath, 'utf8'))).toMatchObject({
      wikiDriftCount: 0,
    });
  });

  test('creates nothing and returns null when the cache file is absent', () => {
    writeState(headOf(root));

    expect(refreshWikiDriftInCache(root)).toBeNull();
    expect(existsSync(path.join(root, '.gaia'))).toBe(false);
  });

  test.each([
    ['unparseable JSON', '{not json'],
    ['a JSON array', '[1, 2]'],
    ['JSON null', 'null'],
  ])('leaves the file untouched for %s', (_label, contents) => {
    writeState(headOf(root));
    seed(contents);

    expect(refreshWikiDriftInCache(root)).toBeNull();
    expect(readFileSync(cachePath, 'utf8')).toBe(contents);
  });

  test("from a linked worktree, measures and writes the main checkout's drift", () => {
    writeState(headOf(root));
    commit(root, 'feat: main moves on');
    seed(JSON.stringify({checkedAt: 5, wikiDriftCount: 0}));
    const linked = path.join(root, '.claude', 'worktrees', 'linked');
    execFileSync('git', ['worktree', 'add', '-q', '-b', 'linked', linked], {
      cwd: root,
    });
    commit(linked, 'feat: only on the linked branch');

    expect(refreshWikiDriftInCache(linked)).toBe(1);
    expect(existsSync(path.join(linked, '.gaia'))).toBe(false);
  });
});
