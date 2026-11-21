import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {execGaiaGit} from '../util/git-env.js';
import {
  writeBuiltinDescriptor,
  writeFrontendRegistry,
  writeMemberRegistry,
} from '../util/package-fixture.js';
import {run as runComponent} from './component.js';
import {run as runHook} from './hook.js';
import {run as runRoute} from './route.js';
import {run as runService} from './service.js';

type Scaffolder = {
  /** Files the scaffolder writes, relative to the package directory. */
  expected: readonly string[];
  name: string;
  run: (cwd: string, extra?: readonly string[]) => number;
  /** Directories that must exist in the package before it runs. */
  seed: readonly string[];
};

const SCAFFOLDERS: readonly Scaffolder[] = [
  {
    expected: ['app/components/widget/index.tsx'],
    name: 'component',
    run: (cwd, extra = []) => runComponent(['Widget', ...extra], {cwd}),
    seed: ['app/components'],
  },
  {
    expected: ['app/hooks/use-widget.ts'],
    name: 'hook',
    run: (cwd, extra = []) => runHook(['useWidget', ...extra], {repoRoot: cwd}),
    seed: [],
  },
  {
    expected: ['app/routes/_public.widget.tsx'],
    name: 'route',
    run: (cwd, extra = []) =>
      runRoute(['widget', '--group', '_public', ...extra], {cwd}),
    seed: [],
  },
  {
    expected: [
      'app/services/gaia/widgets/parsers.ts',
      'test/mocks/widgets/index.ts',
    ],
    name: 'service',
    run: (cwd, extra = []) =>
      runService(
        [
          'widgets',
          '--endpoints',
          'get',
          '--schema',
          'id:string',
          '--mocks',
          ...extra,
        ],
        {cwd}
      ),
    seed: ['app/services/gaia', 'test/mocks'],
  },
];

const listFiles = (directory: string): string[] =>
  readdirSync(directory, {recursive: true, withFileTypes: true})
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(entry.parentPath, entry.name));

const seedPackage = (packageDir: string, seed: readonly string[]): void => {
  mkdirSync(packageDir, {recursive: true});

  for (const relative of seed) {
    mkdirSync(path.join(packageDir, relative), {recursive: true});
  }

  if (seed.includes('test/mocks')) {
    writeFileSync(
      path.join(packageDir, 'test/mocks/database.ts'),
      [
        'export const resetTestData = async (): Promise<void> => {',
        '  await Promise.all([]);',
        '};',
        '',
        'export default {} as Record<string, never>;',
        '',
      ].join('\n')
    );
  }
};

describe.each(SCAFFOLDERS)('gaia scaffold $name package root', (scaffolder) => {
  let root: string;
  let stderrWrites: string[];

  beforeEach(() => {
    // `git` reports the physical path, and os.tmpdir() is a symlink on macOS.
    root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-package-root-')));
    execGaiaGit(['init', '-q', '-b', 'main'], root);
    stderrWrites = [];
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
      stderrWrites.push(String(chunk));

      return true;
    });
    vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(root, {force: true, recursive: true});
  });

  test('a malformed registry refuses with the gaia-packages message and writes nothing', () => {
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    writeFileSync(path.join(root, '.gaia/packages.json'), '{not json');
    const before = listFiles(root).filter((file) => !file.includes('.git/'));

    expect(scaffolder.run(root)).not.toBe(EXIT_CODES.OK);

    expect(stderrWrites.join('')).toContain('gaia-packages:');
    expect(listFiles(root).filter((file) => !file.includes('.git/'))).toEqual(
      before
    );
    expect(existsSync(path.join(root, 'app'))).toBe(false);
    expect(existsSync(path.join(root, 'apps', 'web'))).toBe(false);
  });
});

describe.each(SCAFFOLDERS)('gaia scaffold $name web member', (scaffolder) => {
  let root: string;
  let stderrWrites: string[];

  const snapshot = (): string[] =>
    listFiles(root).filter((file) => !file.includes('.git/'));

  beforeEach(() => {
    root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-web-member-')));
    execGaiaGit(['init', '-q', '-b', 'main'], root);
    stderrWrites = [];
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
      stderrWrites.push(String(chunk));

      return true;
    });
    vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(root, {force: true, recursive: true});
  });

  describe('scaffold resolves the package root for each layout', () => {
    test.each([
      {
        absent: ['app', 'test'],
        cwd: '',
        exists: ['apps/web'],
        extra: [] as string[],
        missing: [] as string[],
        name: 'built-in default writes under apps/web/ when run from the repo root',
        setup: (): void => {
          writeBuiltinDescriptor(root);
          seedPackage(path.join(root, 'apps', 'web'), scaffolder.seed);
        },
      },
      {
        absent: ['app', 'test'],
        cwd: 'apps/web',
        exists: ['apps/web'],
        extra: [] as string[],
        missing: [] as string[],
        name: 'built-in default writes under apps/web/ when run from inside apps/web/',
        setup: (): void => {
          writeBuiltinDescriptor(root);
          seedPackage(path.join(root, 'apps', 'web'), scaffolder.seed);
        },
      },
      {
        absent: ['apps/web'],
        cwd: '',
        exists: ['.'],
        extra: [] as string[],
        missing: [] as string[],
        name: 'a path-"." registry keeps the app at the repo root',
        setup: (): void => {
          writeFrontendRegistry(root, '.');
          seedPackage(root, scaffolder.seed);
        },
      },
      {
        absent: ['packages/lib/app', 'apps/web'],
        cwd: 'packages/lib',
        exists: ['apps/storefront'],
        extra: [] as string[],
        missing: [] as string[],
        name: 'a web member named storefront receives the scaffold, from inside a non-web member',
        setup: (): void => {
          writeMemberRegistry(root, [
            {name: 'lib', path: 'packages/lib', web: false},
            {name: 'storefront', path: 'apps/storefront'},
          ]);
          seedPackage(path.join(root, 'apps/storefront'), scaffolder.seed);
        },
      },
      {
        absent: [] as string[],
        cwd: '',
        exists: ['apps/admin'],
        extra: ['--package', 'admin'],
        missing: ['apps/storefront'],
        name: '--package picks one of two web members',
        setup: (): void => {
          writeMemberRegistry(root, [
            {name: 'storefront', path: 'apps/storefront'},
            {name: 'admin', path: 'apps/admin'},
          ]);
          seedPackage(path.join(root, 'apps/storefront'), scaffolder.seed);
          seedPackage(path.join(root, 'apps/admin'), scaffolder.seed);
        },
      },
    ])('$name', ({absent, cwd, exists, extra, missing, setup}) => {
      setup();

      expect(scaffolder.run(path.join(root, cwd), extra)).toBe(EXIT_CODES.OK);

      for (const packageDir of exists) {
        for (const relative of scaffolder.expected) {
          expect(existsSync(path.join(root, packageDir, relative))).toBe(true);
        }
      }

      for (const packageDir of missing) {
        for (const relative of scaffolder.expected) {
          expect(existsSync(path.join(root, packageDir, relative))).toBe(false);
        }
      }

      for (const relative of absent) {
        expect(existsSync(path.join(root, relative))).toBe(false);
      }
    });
  });

  describe('scaffold refuses a wrong or ambiguous web member', () => {
    test.each([
      {
        extra: ['--package', 'lib'],
        members: [
          {name: 'lib', path: 'packages/lib', web: false},
          {name: 'storefront', path: 'apps/storefront'},
        ],
        name: '--package naming a non-web member refuses, names the web member, and changes no file',
        named: ['storefront'],
        seeded: ['apps/storefront'],
      },
      {
        extra: [] as string[],
        members: [
          {name: 'storefront', path: 'apps/storefront'},
          {name: 'admin', path: 'apps/admin'},
        ],
        name: 'two web members with no flag refuse naming both and change no file',
        named: ['storefront', 'admin'],
        seeded: ['apps/storefront', 'apps/admin'],
      },
    ])('$name', ({extra, members, named, seeded}) => {
      writeMemberRegistry(root, members);

      for (const memberDir of seeded) {
        seedPackage(path.join(root, memberDir), scaffolder.seed);
      }
      const before = snapshot();

      expect(scaffolder.run(root, extra)).toBe(EXIT_CODES.CONFIG_INVALID);

      for (const memberName of named) {
        expect(stderrWrites.join('')).toContain(memberName);
      }
      expect(snapshot()).toEqual(before);
    });
  });
});

describe('gaia scaffold component --parent normalization', () => {
  let root: string;

  beforeEach(() => {
    root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-parent-')));
    writeBuiltinDescriptor(root);
    execGaiaGit(['init', '-q', '-b', 'main'], root);
    mkdirSync(path.join(root, 'apps/web/app/components/form'), {
      recursive: true,
    });
    vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(root, {force: true, recursive: true});
  });

  test.each(['app/components/form', 'apps/web/app/components/form'])(
    'resolves --parent %s against the package and titles the story package-relative',
    (parent) => {
      expect(runComponent(['Field', '--parent', parent], {cwd: root})).toBe(
        EXIT_CODES.OK
      );

      const story = readFileSync(
        path.join(
          root,
          'apps/web/app/components/form/field/tests/index.stories.tsx'
        ),
        'utf8'
      );

      expect(story).toContain('Components/Form/Field');
      expect(existsSync(path.join(root, 'apps/web/frontend'))).toBe(false);
    }
  );
});
