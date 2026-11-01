import {afterEach, describe, expect, test} from 'vitest';
import {existsSync, mkdirSync, readdirSync, rmSync, symlinkSync} from 'node:fs';
import path from 'node:path';
import {
  CACHE,
  cacheTree,
  DEFAULT_KEYS,
  makeBareRepo,
  manifestText,
  OLD,
  read,
  rekeyedOf,
  snapshot,
  write,
} from './__tests__/crossing-fixture.js';
import {parseRekeyArguments, runRekey} from './crossing-rekey.js';

const roots: string[] = [];

const project = (): string => {
  const root = makeBareRepo();

  roots.push(root);

  return root;
};

const leftovers = (root: string, tag: string): string[] =>
  readdirSync(path.join(root, CACHE, tag)).filter((name) =>
    name.startsWith('tree-rekeyed')
  );

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, {force: true, recursive: true});
  }
});

describe('parseRekeyArguments', () => {
  test('collects the baseline tag and every extra tag', () => {
    expect(
      parseRekeyArguments([
        '--baseline-tag',
        'v2.3.0',
        '--extra-tag',
        'v2.2.0',
        '--extra-tag',
        'v2.1.0',
      ])
    ).toEqual({
      baselineTag: 'v2.3.0',
      extraTags: ['v2.2.0', 'v2.1.0'],
      ok: true,
    });
  });

  test.each([
    [[]],
    [['--baseline-tag']],
    [['--baseline-tag', 'v2.3.0', '--path', 'x']],
    [['--baseline-tag', '../escape']],
    [['--baseline-tag', 'v2.3.0', '--extra-tag', 'a/b']],
  ])('refuses %j', (argv) => {
    expect(parseRekeyArguments(argv).ok).toBe(false);
  });
});

describe('runRekey tree', () => {
  test('maps a leading old root only and prints the rekeyed directories', () => {
    const root = project();

    cacheTree(root, 'v2.3.0');
    cacheTree(root, 'v2.2.0');
    const outcome = runRekey(root, {
      baselineTag: 'v2.3.0',
      extraTags: ['v2.2.0'],
    });

    expect(outcome.exit).toBe(0);
    expect(outcome.lines).toEqual([
      `BASELINE_DIR=${CACHE}/v2.3.0/tree-rekeyed`,
      `EXTRA_DIR=v2.2.0:${CACHE}/v2.2.0/tree-rekeyed`,
    ]);
    const rekeyed = rekeyedOf(root, 'v2.3.0');

    expect(read(rekeyed, 'apps/web/app/x')).toBe(
      `content of ${OLD('app/x')}\n`
    );
    expect(existsSync(path.join(rekeyed, OLD('app/x')))).toBe(false);
    expect(read(rekeyed, '.claude/agents/code-audit-frontend/y.md')).toContain(
      'y.md'
    );
    expect(read(rekeyed, 'docs/frontend/z.md')).toContain('z.md');
    const manifest = JSON.parse(read(rekeyed, '.gaia/manifest.json'));

    expect(Object.keys(manifest.files)).toEqual([
      '.claude/agents/code-audit-frontend/y.md',
      '.gaia/VERSION',
      'apps/web/app/x',
      'apps/web/package.json',
      'docs/frontend/z.md',
    ]);
    expect(manifest.version).toBe('2.3.0');
    expect(existsSync(path.join(rekeyed, '.source-digest'))).toBe(true);
  });

  test('leaves the source tree untouched', () => {
    const root = project();
    const tree = cacheTree(root, 'v2.3.0');
    const before = snapshot(tree);

    runRekey(root, {baselineTag: 'v2.3.0', extraTags: []});

    expect(snapshot(tree)).toEqual(before);
    expect(leftovers(root, 'v2.3.0')).toEqual(['tree-rekeyed']);
  });

  test('a baseline tag repeated as an extra tag is processed once', () => {
    const root = project();

    cacheTree(root, 'v2.3.0');
    const outcome = runRekey(root, {
      baselineTag: 'v2.3.0',
      extraTags: ['v2.3.0'],
    });

    expect(outcome.lines).toHaveLength(2);
  });

  const REFUSALS: [string, (root: string, tree: string) => void, string][] = [
    [
      'a symlink in the tree',
      (_root, tree) => {
        symlinkSync('.gaia/VERSION', path.join(tree, 'link'));
      },
      'symlink',
    ],
    [
      'a parent-relative manifest key',
      (_root, tree) => {
        write(
          tree,
          '.gaia/manifest.json',
          manifestText(['../escape', OLD('a')])
        );
      },
      'manifest-key',
    ],
    [
      'an absolute manifest key',
      (_root, tree) => {
        write(tree, '.gaia/manifest.json', manifestText(['/etc/passwd']));
      },
      'manifest-key',
    ],
    [
      'a backslash manifest key',
      (_root, tree) => {
        write(tree, '.gaia/manifest.json', manifestText([String.raw`a\b`]));
      },
      'manifest-key',
    ],
    [
      'a double-slash manifest key',
      (_root, tree) => {
        write(tree, '.gaia/manifest.json', manifestText(['a//b']));
      },
      'manifest-key',
    ],
    [
      'a manifest key already under the new home',
      (_root, tree) => {
        write(
          tree,
          '.gaia/manifest.json',
          manifestText([OLD('a'), 'apps/web/a'])
        );
      },
      'new-home-occupied',
    ],
    [
      'a file already under the new home',
      (_root, tree) => {
        write(tree, 'apps/web/stray', 'x\n');
      },
      'new-home-occupied',
    ],
    [
      'a missing manifest',
      (_root, tree) => {
        rmSync(path.join(tree, '.gaia/manifest.json'));
      },
      'manifest-unreadable',
    ],
  ];

  test.each(REFUSALS)(
    'refuses %s and changes nothing',
    (_label, damage, reason) => {
      const root = project();
      const tree = cacheTree(root, 'v2.3.0');

      damage(root, tree);
      const before = snapshot(path.join(root, CACHE));
      const outcome = runRekey(root, {baselineTag: 'v2.3.0', extraTags: []});

      expect(outcome.exit).toBe(3);
      expect(outcome.lines[0]).toBe(`CROSSING_STOP ${reason}`);
      expect(snapshot(path.join(root, CACHE))).toEqual(before);
    }
  );

  test('a missing source tree stops', () => {
    const root = project();
    const outcome = runRekey(root, {baselineTag: 'v2.3.0', extraTags: []});

    expect(outcome.exit).toBe(3);
    expect(outcome.lines[0]).toBe('CROSSING_STOP tree-missing');
  });

  test('a prior rekey with a matching digest is reused', () => {
    const root = project();

    cacheTree(root, 'v2.3.0');
    runRekey(root, {baselineTag: 'v2.3.0', extraTags: []});
    write(rekeyedOf(root, 'v2.3.0'), 'SENTINEL', 'kept\n');
    runRekey(root, {baselineTag: 'v2.3.0', extraTags: []});

    expect(read(rekeyedOf(root, 'v2.3.0'), 'SENTINEL')).toBe('kept\n');
  });

  test('a prior rekey with a different digest is rebuilt', () => {
    const root = project();

    cacheTree(root, 'v2.3.0');
    runRekey(root, {baselineTag: 'v2.3.0', extraTags: []});
    write(rekeyedOf(root, 'v2.3.0'), 'SENTINEL', 'stale\n');
    cacheTree(root, 'v2.3.0', [...DEFAULT_KEYS, OLD('app/new')]);
    runRekey(root, {baselineTag: 'v2.3.0', extraTags: []});

    expect(existsSync(path.join(rekeyedOf(root, 'v2.3.0'), 'SENTINEL'))).toBe(
      false
    );
    expect(read(rekeyedOf(root, 'v2.3.0'), 'apps/web/app/new')).toContain(
      'new'
    );
  });

  test('a prior rekey with no digest is rebuilt and stale temporary trees are cleared', () => {
    const root = project();

    cacheTree(root, 'v2.3.0');
    write(rekeyedOf(root, 'v2.3.0'), 'SENTINEL', 'half\n');
    mkdirSync(path.join(root, CACHE, 'v2.3.0', 'tree-rekeyed.tmp.dead'));
    runRekey(root, {baselineTag: 'v2.3.0', extraTags: []});

    expect(existsSync(path.join(rekeyedOf(root, 'v2.3.0'), 'SENTINEL'))).toBe(
      false
    );
    expect(leftovers(root, 'v2.3.0')).toEqual(['tree-rekeyed']);
  });
});
