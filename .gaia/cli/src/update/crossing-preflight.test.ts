import {afterEach, describe, expect, test} from 'vitest';
import {mkdirSync, rmSync} from 'node:fs';
import path from 'node:path';
import {
  git,
  indexState,
  makeLegacyRepo,
  OLD,
  OLD_ROOT,
  snapshot,
  write,
} from './__tests__/crossing-fixture.js';
import {runPreflight} from './crossing-preflight.js';

const roots: string[] = [];

const fresh = (options?: Parameters<typeof makeLegacyRepo>[0]): string => {
  const root = makeLegacyRepo(options);

  roots.push(root);

  return root;
};

const commitAll = (root: string): void => {
  git(root, ['add', '-A']);
  git(root, ['commit', '-q', '-m', 'change']);
};

const observed = (root: string): string[] => [
  git(root, ['status', '--porcelain']),
  git(root, ['rev-parse', 'HEAD']),
  git(root, ['branch', '--list']),
  indexState(root),
  JSON.stringify(snapshot(root)),
];

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, {force: true, recursive: true});
  }
});

type StopRow = {
  name: string;
  prepare: (root: string) => string | undefined;
  reason: string;
};

const STOP_ROWS: StopRow[] = [
  {
    name: 'an untracked file',
    prepare: (root) => {
      write(root, 'stray.txt', 'x\n');
    },
    reason: 'dirty-tree',
  },
  {
    name: 'a linked worktree',
    prepare: (root) => {
      const linked = `${root}-linked`;

      roots.push(linked);
      git(root, ['worktree', 'add', '-q', '-b', 'side', linked]);

      return linked;
    },
    reason: 'linked-worktree',
  },
  {
    name: 'a launch from a subdirectory',
    prepare: (root) => path.join(root, OLD('app')),
    reason: 'not-root-launch',
  },
  {
    name: 'a plan that is executing',
    prepare: (root) => {
      write(root, '.notebook/specs/SPEC-1/plan/RUNNING', '');
    },
    reason: 'plan-in-execution',
  },
  {
    name: 'a branch that is not the default',
    prepare: (root) => {
      git(root, ['checkout', '-q', '-b', 'topic']);
    },
    reason: 'default-branch-behind',
  },
  {
    name: 'a default branch that is not level with origin',
    prepare: (root) => {
      const head = git(root, ['rev-parse', 'HEAD']).trim();

      write(root, 'later.txt', 'x\n');
      commitAll(root);
      git(root, ['update-ref', 'refs/remotes/origin/main', head]);
      git(root, [
        'symbolic-ref',
        'refs/remotes/origin/HEAD',
        'refs/remotes/origin/main',
      ]);
    },
    reason: 'default-branch-behind',
  },
  {
    name: 'a registry with no member at the old path',
    prepare: (root) => {
      write(root, '.gaia/packages.json', '[{"name":"tools","path":"tools"}]\n');
      commitAll(root);
    },
    reason: 'registry-path',
  },
  {
    name: 'a malformed registry',
    prepare: (root) => {
      write(root, '.gaia/packages.json', '{"not":"an array"}\n');
      commitAll(root);
    },
    reason: 'registry-path',
  },
  {
    name: 'both trees present',
    prepare: (root) => {
      write(root, 'apps/web/package.json', '{}\n');
      commitAll(root);
    },
    reason: 'both-trees-present',
  },
  {
    name: 'another member named web',
    prepare: (root) => {
      write(
        root,
        '.gaia/packages.json',
        `[{"name":"frontend","path":"${OLD_ROOT}"},{"name":"web","path":"tools/web"}]\n`
      );
      commitAll(root);
    },
    reason: 'member-named-web',
  },
];

describe('runPreflight stops', () => {
  test.each(STOP_ROWS)(
    '$name stops with $reason and changes nothing',
    (row) => {
      const root = fresh();
      const launch = row.prepare(root) ?? root;
      const before = observed(root);
      const outcome = runPreflight(launch);

      expect(outcome.exit).toBe(3);
      expect(outcome.lines[0]).toBe(`CROSSING_STOP ${row.reason}`);
      expect(outcome.lines[1]).toMatch(/^Next step: \S/u);
      expect(observed(root)).toEqual(before);
    }
  );
});

describe('runPreflight passes', () => {
  test('a clean default branch passes as fresh', () => {
    const root = fresh();

    expect(runPreflight(root)).toEqual({
      exit: 0,
      lines: ['CROSSING_PASS fresh'],
    });
  });

  test('an absent registry reads as the app at the old path', () => {
    const root = fresh({registry: false});

    expect(runPreflight(root).lines).toEqual(['CROSSING_PASS fresh']);
  });

  test('a kept name at the old path passes with no question', () => {
    const root = fresh({name: 'storefront'});

    expect(runPreflight(root).lines).toEqual(['CROSSING_PASS fresh']);
  });

  test('a moved app with the manifest still keyed on the old root resumes, dirty and off the default branch', () => {
    const root = fresh();

    git(root, ['checkout', '-q', '-b', 'update/x']);
    mkdirSync(path.join(root, 'apps'));
    git(root, ['mv', OLD_ROOT, 'apps/web']);
    write(root, 'uncommitted.txt', 'work\n');

    expect(runPreflight(root)).toEqual({
      exit: 0,
      lines: ['CROSSING_PASS resume'],
    });
  });

  test('a hand-moved app on a clean default branch with the registry unchanged passes', () => {
    const root = fresh();

    mkdirSync(path.join(root, 'apps'));
    git(root, ['mv', OLD_ROOT, 'apps/web']);
    commitAll(root);

    expect(runPreflight(root).exit).toBe(0);
  });

  test('a second member named web at the old path is the kept name, not a collision', () => {
    const root = fresh({name: 'web'});

    expect(runPreflight(root).lines).toEqual(['CROSSING_PASS fresh']);
  });
});
