import {afterEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  unlinkSync,
} from 'node:fs';
import path from 'node:path';
import {
  DESCRIPTOR,
  git,
  indexState,
  makeLegacyRepo,
  OLD,
  OLD_ROOT,
  read,
  snapshot,
  WORKSPACE,
  write,
} from './__tests__/crossing-fixture.js';
import {runMove} from './crossing-move.js';

const roots: string[] = [];

const fresh = (options?: Parameters<typeof makeLegacyRepo>[0]): string => {
  const root = makeLegacyRepo(options);

  roots.push(root);

  return root;
};

/** Everything the move owns: files outside the local cache, and the index. */
const treeState = (
  root: string
): {files: Record<string, string>; index: string} => ({
  files: Object.fromEntries(
    Object.entries(snapshot(root)).filter(
      ([file]) => !file.startsWith('.gaia/local/')
    )
  ),
  index: indexState(root),
});

const tracked = (root: string, file: string): boolean => {
  try {
    git(root, ['ls-files', '--error-unmatch', '--', file]);

    return true;
  } catch {
    return false;
  }
};

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, {force: true, recursive: true});
  }
});

describe('runMove on a 2.x install', () => {
  test('moves the app and finishes every edit', () => {
    const root = fresh();
    const envBefore = read(root, OLD('.env'));
    const outcome = runMove(root);

    expect(outcome.exit).toBe(0);
    expect(existsSync(path.join(root, OLD_ROOT))).toBe(false);
    expect(read(root, 'apps/web/app/x.ts')).toBe('export const x = 1;\n');
    expect(read(root, 'apps/web/.env')).toBe(envBefore);
    expect(
      existsSync(path.join(root, 'apps/web/node_modules/dep/index.js'))
    ).toBe(true);
    expect(read(root, '.gaia/packages.json')).toBe(
      '[{"name":"web","path":"apps/web"}]\n'
    );
    expect(JSON.parse(read(root, 'apps/web/package.json'))).toMatchObject({
      name: 'web',
    });
    expect(JSON.parse(read(root, 'apps/web/gaia.package.json'))).toMatchObject({
      name: 'web',
      stack: 'web',
    });
    expect(read(root, 'pnpm-workspace.yaml')).toBe(
      WORKSPACE.replace('  - frontend\n', '  - apps/*\n').replace(
        '  - .gaia/cli\n',
        '  - .gaia/cli\n  - packages/*\n'
      )
    );
    expect(tracked(root, 'packages/.gitkeep')).toBe(true);
  });

  test('records the ignored files, paths only, and carries their bytes', () => {
    const root = fresh();

    runMove(root);
    const recorded = read(
      root,
      '.gaia/local/cache/shared/update-gaia/crossing-ignored.txt'
    );

    expect(recorded.split('\n')).toContain(OLD('.env'));
    expect(recorded).not.toContain('SECRET');
    expect(read(root, 'apps/web/.env')).toBe('SECRET=abc\n');
  });

  test('stages no unrelated file', () => {
    const root = fresh();

    write(root, 'unrelated.txt', 'mine\n');
    runMove(root);

    expect(tracked(root, 'unrelated.txt')).toBe(false);
    expect(git(root, ['status', '--porcelain'])).toContain('?? unrelated.txt');
  });

  test('a kept member name stays in the registry, descriptor and package', () => {
    const root = fresh({name: 'storefront'});

    runMove(root);

    expect(read(root, '.gaia/packages.json')).toBe(
      '[{"name":"storefront","path":"apps/web"}]\n'
    );
    expect(JSON.parse(read(root, 'apps/web/package.json')).name).toBe(
      'storefront'
    );
    expect(JSON.parse(read(root, 'apps/web/gaia.package.json'))).toMatchObject({
      name: 'storefront',
      stack: 'web',
    });
  });

  test('an absent registry is written out for the new home', () => {
    const root = fresh({registry: false});

    runMove(root);

    expect(read(root, '.gaia/packages.json')).toBe(
      '[{"name":"web","path":"apps/web"}]\n'
    );
    expect(tracked(root, '.gaia/packages.json')).toBe(true);
  });

  test('reports folders the globs newly match and flags lifecycle scripts', () => {
    const root = fresh();

    write(
      root,
      'apps/legacy/package.json',
      '{"scripts":{"postinstall":"x"}}\n'
    );
    git(root, ['add', '-A']);
    git(root, ['commit', '-q', '-m', 'legacy']);
    const outcome = runMove(root);

    expect(outcome.lines).toContain('REPORT\tnewly-matched\tapps/legacy');
    expect(outcome.lines).toContain(
      'REPORT\tlifecycle-scripts\tapps/legacy: postinstall'
    );
  });

  test('marks another member with generated settings or an overlay', () => {
    const root = fresh();

    write(
      root,
      '.gaia/packages.json',
      `[{"name":"frontend","path":"${OLD_ROOT}"},{"name":"tools","path":"tools"},{"name":"plain","path":"plain"}]\n`
    );
    write(root, 'tools/gaia.package.json', DESCRIPTOR('tools'));
    write(root, 'tools/.claude/settings.overlay.json', '{}\n');
    write(root, 'plain/gaia.package.json', DESCRIPTOR('plain'));
    git(root, ['add', '-A']);
    git(root, ['commit', '-q', '-m', 'members']);
    const outcome = runMove(root);

    expect(
      JSON.parse(read(root, 'tools/gaia.package.json')).generatedSettings
    ).toBe(true);
    expect(read(root, 'plain/gaia.package.json')).toBe(DESCRIPTOR('plain'));
    expect(outcome.lines).toContain('REPORT\tgenerated-settings\ttools');
    expect(read(root, '.gaia/packages.json')).toContain(
      '{"name":"tools","path":"tools"}'
    );
  });
});

describe('runMove is idempotent per step', () => {
  test('a second run on a finished tree changes nothing and exits 0', () => {
    const root = fresh();

    runMove(root);
    const settled = treeState(root);
    const outcome = runMove(root);

    expect(outcome.exit).toBe(0);
    expect(treeState(root)).toEqual(settled);
  });

  const UNDO_ROWS: [string, (root: string) => void][] = [
    [
      'the registry back at the old path',
      (root) => {
        write(
          root,
          '.gaia/packages.json',
          `[{"name":"frontend","path":"${OLD_ROOT}"}]\n`
        );
      },
    ],
    [
      'the descriptor without a stack',
      (root) => {
        write(root, 'apps/web/gaia.package.json', DESCRIPTOR('web'));
      },
    ],
    [
      'the package name restored',
      (root) => {
        write(
          root,
          'apps/web/package.json',
          '{\n  "name": "frontend",\n  "private": true\n}\n'
        );
      },
    ],
    [
      'the workspace list restored',
      (root) => {
        write(root, 'pnpm-workspace.yaml', WORKSPACE);
      },
    ],
    [
      'the keep file removed',
      (root) => {
        unlinkSync(path.join(root, 'packages/.gitkeep'));
      },
    ],
  ];

  test.each(UNDO_ROWS)(
    'undoing %s then re-running ends equal to an uninterrupted run',
    (_label, undo) => {
      const uninterrupted = fresh();
      const interrupted = fresh();

      runMove(uninterrupted);
      runMove(interrupted);
      undo(interrupted);
      const outcome = runMove(interrupted);

      expect(outcome.exit).toBe(0);
      expect(treeState(interrupted)).toEqual(treeState(uninterrupted));
    }
  );

  test('a hand-moved app with the registry still at the old path ends equal', () => {
    const uninterrupted = fresh();
    const handMoved = fresh();

    runMove(uninterrupted);
    mkdirSync(path.join(handMoved, 'apps'));
    git(handMoved, ['mv', OLD_ROOT, 'apps/web']);
    git(handMoved, ['commit', '-q', '-m', 'hand move']);
    const outcome = runMove(handMoved);

    expect(outcome.exit).toBe(0);
    expect(treeState(handMoved).files).toEqual(treeState(uninterrupted).files);
  });
});

const removeOldRoot = (root: string): void => {
  git(root, ['rm', '-r', '-q', '-f', OLD_ROOT]);
  rmSync(path.join(root, OLD_ROOT), {force: true, recursive: true});
};

describe('runMove refusals change nothing', () => {
  const REFUSAL_ROWS: {
    arrange: (root: string) => void;
    name: string;
    stop: string;
  }[] = [
    {
      arrange: (root) => {
        mkdirSync(path.join(root, 'elsewhere'));
        symlinkSync('elsewhere', path.join(root, 'apps'));
      },
      name: 'a symlink at the apps directory',
      stop: 'CROSSING_STOP symlink',
    },
    {
      arrange: (root) => {
        removeOldRoot(root);
        mkdirSync(path.join(root, 'elsewhere'));
        symlinkSync('elsewhere', path.join(root, OLD_ROOT));
      },
      name: 'a symlink at the old root',
      stop: 'CROSSING_STOP symlink',
    },
    {
      arrange: (root) => {
        write(root, 'apps/web/package.json', '{}\n');
      },
      name: 'both trees present',
      stop: 'CROSSING_STOP both-trees-present',
    },
    {
      arrange: removeOldRoot,
      name: 'neither tree present',
      stop: 'CROSSING_STOP app-missing',
    },
  ];

  test.each(REFUSAL_ROWS.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {arrange, stop}) => {
      const root = fresh();

      arrange(root);
      const before = treeState(root);
      const outcome = runMove(root);

      expect(outcome.exit).toBe(3);
      expect(outcome.lines[0]).toBe(stop);
      expect(treeState(root)).toEqual(before);
    }
  );
});

test('the move leaves the manifest and decision log to rekey', () => {
  const root = fresh();
  const manifest = readFileSync(path.join(root, '.gaia/manifest.json'), 'utf8');

  runMove(root);

  expect(read(root, '.gaia/manifest.json')).toBe(manifest);
});
