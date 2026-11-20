import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {
  captureStderr,
  captureStdout,
  expectNoRouteImports,
  ONE_LINE_RENDER,
  scaffold,
  setupSandbox,
} from './route-fixture.js';
import type {Sandbox} from './route-fixture.js';
import {run} from './route.js';
import {csf4Violations} from './story-shape-fixture.js';

const seedLocaleBarrel = (fakeRoot: string, body: string): string => {
  const dir = path.join(fakeRoot, 'app', 'languages', 'en', 'pages');
  mkdirSync(dir, {recursive: true});
  const filePath = path.join(dir, 'index.ts');
  writeFileSync(filePath, body, 'utf8');

  return filePath;
};

const INDEX_BARREL = [
  "import index from './_index';",
  '',
  'export default {',
  '  index,',
  '};',
  '',
].join('\n');

const sessionRouteFile = (root: string): string =>
  path.join(root, 'app', 'routes', '_session.dashboard.tsx');

// The page renders the document head from the loader data, typed by the page
// folder's own `types.ts`, never by importing the route module.
const expectLoaderPageAndStory = (root: string): void => {
  const body = readFileSync(sessionRouteFile(root), 'utf8');
  expect(body).toMatch(ONE_LINE_RENDER);

  const pageDir = path.join(root, 'app', 'pages', 'dashboard');
  const page = readFileSync(path.join(pageDir, 'page.tsx'), 'utf8');
  expect(page).toContain('useLoaderData<LoaderData>()');
  expect(page).toContain('<title>{title}</title>');
  expect(page).toContain('<meta content={description} name="description" />');
  expect(page).toContain("import type {LoaderData} from './types'");
  expect(readFileSync(path.join(pageDir, 'types.ts'), 'utf8')).toContain(
    'export type LoaderData'
  );
  expectNoRouteImports(pageDir);

  const story = readFileSync(
    path.join(pageDir, 'tests', 'page.stories.tsx'),
    'utf8'
  );
  expect(csf4Violations(story)).toEqual([]);
  expect(story).toContain('stubs.reactRouter({');
  expect(story).toContain('loader: async () => ({');
};

describe('scaffold route: argument validation', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-route-');
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test.each([
    {
      args: ['dashboard'],
      contains: ['--group is required', '_public', '_session'],
      excludes: [] as string[],
      name: 'rejects missing --group',
    },
    {
      args: ['dashboard', '--group', '_admin'],
      contains: ['--group must be one of'],
      excludes: [] as string[],
      name: 'rejects invalid --group value',
    },
    {
      args: ['dashboard', '--group', '_session+'],
      contains: ['_public', '_session'],
      excludes: ['_public+', '_session+'],
      name: 'rejects the retired trailing-+ group spelling',
    },
    {
      args: ['Dashboard', '--group', '_session'],
      contains: ['kebab-case'],
      excludes: [] as string[],
      name: 'rejects non-kebab name',
    },
    {
      args: ['dashboard', '--group', '_session', '--bogus'],
      contains: ['invalid or unknown flag'],
      excludes: [] as string[],
      name: 'rejects unknown flag',
    },
    ...['tests', 'hooks', 'state', 'utils', 'assets'].map((reservedName) => ({
      args: [reservedName, '--group', '_public'],
      contains: ['reserved'],
      excludes: [] as string[],
      name: `rejects the reserved page-folder name ${reservedName} and writes nothing`,
    })),
    {
      args: [] as string[],
      contains: [] as string[],
      excludes: [] as string[],
      name: 'prints help when invoked with no args',
    },
  ])('$name', ({args, contains, excludes}) => {
    const result = scaffold(sandbox.root, args);

    expect(result.exit).toBe(1);

    for (const fragment of contains) {
      expect(result.stderr).toContain(fragment);
    }

    for (const fragment of excludes) {
      expect(result.stderr).not.toContain(fragment);
    }
    expect(existsSync(path.join(sandbox.root, 'app'))).toBe(false);
  });
});

describe('scaffold route: base emission (_session)', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-route-');
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('emits route file, page index, and story with no test file', () => {
    const stdout = captureStdout();
    const exit = run(['dashboard', '--group', '_session'], {
      cwd: sandbox.root,
    });
    stdout.restore();

    expect(exit).toBe(0);

    const routeFile = path.join(
      sandbox.root,
      'app',
      'routes',
      '_session.dashboard.tsx'
    );
    const pageIndex = path.join(
      sandbox.root,
      'app',
      'pages',
      'dashboard',
      'page.tsx'
    );
    const pageTest = path.join(
      sandbox.root,
      'app',
      'pages',
      'dashboard',
      'tests',
      'page.test.tsx'
    );
    const pageStories = path.join(
      sandbox.root,
      'app',
      'pages',
      'dashboard',
      'tests',
      'page.stories.tsx'
    );

    expect(existsSync(routeFile)).toBe(true);
    expect(existsSync(pageIndex)).toBe(true);
    expect(existsSync(pageTest)).toBe(false);
    expect(existsSync(pageStories)).toBe(true);

    const routeBody = readFileSync(routeFile, 'utf8');
    expect(routeBody).toContain(
      "import DashboardPage from '~/pages/dashboard/page'"
    );
    expect(routeBody).toContain('const DashboardRoute');
    expect(routeBody).toMatch(ONE_LINE_RENDER);
    expect(routeBody).not.toContain('export const loader');
    expect(routeBody).not.toContain('export const action');
    expect(
      existsSync(
        path.join(sandbox.root, 'app', 'pages', 'dashboard', 'types.ts')
      )
    ).toBe(false);
    expectNoRouteImports(path.join(sandbox.root, 'app', 'pages', 'dashboard'));

    const pageBody = readFileSync(pageIndex, 'utf8');
    expect(pageBody).not.toMatch(/\bFC\b/);
    expect(pageBody.startsWith('\n')).toBe(false);
    expect(pageBody).toContain('const DashboardPage = () => {');
    expect(pageBody).toContain('export default DashboardPage');

    const storiesBody = readFileSync(pageStories, 'utf8');
    expect(storiesBody).toContain("title: 'Pages/Dashboard'");
    expect(csf4Violations(storiesBody)).toEqual([]);
  });

  test('hyphenated names map to a kebab page folder', () => {
    const stdout = captureStdout();
    const exit = run(['user-settings', '--group', '_session'], {
      cwd: sandbox.root,
    });
    stdout.restore();

    expect(exit).toBe(0);

    const pageIndex = path.join(
      sandbox.root,
      'app',
      'pages',
      'user-settings',
      'page.tsx'
    );
    expect(existsSync(pageIndex)).toBe(true);

    const routeFile = path.join(
      sandbox.root,
      'app',
      'routes',
      '_session.user-settings.tsx'
    );
    const routeBody = readFileSync(routeFile, 'utf8');
    expect(routeBody).toContain('const UserSettingsRoute');
    expect(routeBody).toContain(
      "import UserSettingsPage from '~/pages/user-settings/page'"
    );
  });

  test('_public group writes the same page folder, with no group segment', () => {
    const stdout = captureStdout();
    const exit = run(['marketing', '--group', '_public'], {
      cwd: sandbox.root,
    });
    stdout.restore();

    expect(exit).toBe(0);

    const pageIndex = path.join(
      sandbox.root,
      'app',
      'pages',
      'marketing',
      'page.tsx'
    );
    const routeFile = path.join(
      sandbox.root,
      'app',
      'routes',
      '_public.marketing.tsx'
    );
    expect(existsSync(pageIndex)).toBe(true);
    expect(existsSync(routeFile)).toBe(true);
  });
});

describe('scaffold route: flag combos', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-route-');
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  describe('scaffold route --loader and --action emit their exports', () => {
    // Without --i18n no `pages` locale keys exist, so a loader that looks them
    // up fails the typed i18next resources at typecheck.
    test.each([
      {
        args: ['dashboard', '--group', '_session', '--loader'],
        barrels: [] as string[],
        contains: [
          'export const loader',
          "import type {LoaderData} from '~/pages/dashboard/types'",
          "title: 'DashboardPage'",
          "description: 'Description of the dashboard page'",
        ],
        excludes: [
          'useLoaderData',
          'i18next',
          'getInstance',
          'RouterContextProvider',
          './+types/',
        ],
        extraCheck: expectLoaderPageAndStory,
        name: '--loader without --i18n emits a loader with no i18next lookup',
      },
      {
        args: ['dashboard', '--group', '_session', '--loader', '--i18n'],
        barrels: [INDEX_BARREL],
        contains: [
          "i18next.t('dashboard.meta.title', {ns: 'pages'})",
          "from '~/middleware/i18next'",
          'Route.LoaderArgs',
          "from './+types/_session.dashboard'",
        ],
        excludes: ["from './+types/dashboard'"],
        extraCheck: () => undefined,
        name: '--loader with --i18n emits a loader reading the pages locale',
      },
      {
        args: ['dashboard', '--group', '_session', '--action'],
        barrels: [] as string[],
        contains: [
          'export const action',
          'Route.ActionArgs',
          "from './+types/_session.dashboard'",
        ],
        excludes: ["from './+types/dashboard'"],
        extraCheck: () => undefined,
        name: '--action emits action export',
      },
      {
        args: ['dashboard', '--group', '_session', '--loader', '--action'],
        barrels: [] as string[],
        contains: [
          'export const loader',
          'export const action',
          "from './+types/_session.dashboard'",
        ],
        excludes: ["from './+types/dashboard'"],
        extraCheck: () => undefined,
        name: '--loader and --action together',
      },
    ])('$name', ({args, barrels, contains, excludes, extraCheck}) => {
      for (const barrel of barrels) {
        seedLocaleBarrel(sandbox.root, barrel);
      }

      expect(scaffold(sandbox.root, args).exit).toBe(0);

      const body = readFileSync(sessionRouteFile(sandbox.root), 'utf8');

      for (const fragment of contains) {
        expect(body).toContain(fragment);
      }

      for (const fragment of excludes) {
        expect(body).not.toContain(fragment);
      }
      extraCheck(sandbox.root);
    });
  });

  test('--i18n with a missing barrel surfaces the failure', () => {
    // No barrel seeded: the locale file is written but cannot be wired.
    const stderr = captureStderr();
    const exit = run(['dashboard', '--group', '_session', '--i18n'], {
      cwd: sandbox.root,
    });
    const out = stderr.restore();

    expect(exit).toBe(1);
    expect(out).toContain('locale barrel at');
  });

  test('--json emits a single ScaffoldResult JSON line', () => {
    const stdout = captureStdout();
    const exit = run(['dashboard', '--group', '_session', '--json'], {
      cwd: sandbox.root,
    });
    const out = stdout.restore();

    expect(exit).toBe(0);
    const parsed = JSON.parse(out.trim()) as Record<string, unknown>;
    expect(parsed).toHaveProperty('written');
    expect(parsed).toHaveProperty('edited');
    expect(parsed).toHaveProperty('skipped');
    expect(Array.isArray(parsed.written)).toBe(true);
  });
});

describe('scaffold route: --dry-run', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-route-');
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test.each([
    {
      args: ['dashboard', '--group', '_session', '--dry-run'],
      barrels: [] as string[],
      name: 'reports would-be writes without touching the filesystem',
      stdoutContains: () => ['dry-run: no files written', 'would write'],
    },
    {
      args: [
        'dashboard',
        '--group',
        '_session',
        '--i18n',
        '--dry-run',
        '--json',
      ],
      barrels: [INDEX_BARREL],
      name: '--dry-run is orthogonal to --json and writes nothing',
      // The barrel is reported as a would-be edit but stays untouched on disk.
      stdoutContains: (barrelPath: string) => ['"written":["', barrelPath],
    },
  ])('$name', ({args, barrels, stdoutContains}) => {
    const barrelPath = path.join(
      sandbox.root,
      'app',
      'languages',
      'en',
      'pages',
      'index.ts'
    );

    for (const barrel of barrels) {
      seedLocaleBarrel(sandbox.root, barrel);
    }

    const result = scaffold(sandbox.root, args);

    expect(result.exit).toBe(0);

    for (const fragment of stdoutContains(barrelPath)) {
      expect(result.stdout).toContain(fragment);
    }
    expect(existsSync(sessionRouteFile(sandbox.root))).toBe(false);
    expect(
      existsSync(
        path.join(sandbox.root, 'app', 'pages', 'dashboard', 'page.tsx')
      )
    ).toBe(false);
    expect(
      existsSync(
        path.join(
          sandbox.root,
          'app',
          'languages',
          'en',
          'pages',
          'dashboard.ts'
        )
      )
    ).toBe(false);

    for (const barrel of barrels) {
      expect(readFileSync(barrelPath, 'utf8')).toBe(barrel);
    }
  });
});

describe('scaffold route: idempotency', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-route-');
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test.each([
    {
      args: ['dashboard', '--group', '_session'],
      barrels: [] as string[],
      name: 'second invocation with same args is a no-op (no throws, files unchanged)',
      occurrences: [] as RegExp[],
      watched: (root: string) => sessionRouteFile(root),
    },
    {
      args: ['dashboard', '--group', '_session', '--i18n'],
      barrels: [INDEX_BARREL],
      name: 'barrel insert is idempotent on re-run',
      occurrences: [/import dashboard from/gu],
      watched: (root: string) =>
        path.join(root, 'app', 'languages', 'en', 'pages', 'index.ts'),
    },
  ])('$name', ({args, barrels, occurrences, watched}) => {
    for (const barrel of barrels) {
      seedLocaleBarrel(sandbox.root, barrel);
    }

    expect(scaffold(sandbox.root, args).exit).toBe(0);
    const afterFirst = readFileSync(watched(sandbox.root), 'utf8');

    expect(scaffold(sandbox.root, args).exit).toBe(0);
    const afterSecond = readFileSync(watched(sandbox.root), 'utf8');

    expect(afterSecond).toBe(afterFirst);

    for (const pattern of occurrences) {
      expect([...afterSecond.matchAll(pattern)]).toHaveLength(1);
    }
  });
});

describe('scaffold route inserts the i18n barrel alphabetically', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-route-');
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test.each([
    {
      blockPattern: /dashboard,[ \t]*\n[ \t]*index,[ \t]*\n[ \t]*legal,/u,
      // Alphabetical: dashboard < index < legal by import-name comparison.
      imports: [
        "import dashboard from './dashboard';",
        "import index from './_index';",
        "import legal from './legal';",
      ],
      localeContains: [
        "description: 'Description of the dashboard page'",
        "title: 'DashboardPage'",
      ],
      name: '--i18n with existing barrel inserts alphabetically',
      pageContains: ["useTranslation('pages', {keyPrefix: 'dashboard'})"],
      route: 'dashboard',
      seed: [
        "import index from './_index';",
        "import legal from './legal';",
        '',
        'export default {',
        '  index,',
        '  legal,',
        '};',
        '',
      ],
    },
    {
      blockPattern: /admin,[ \t]*\n[ \t]*legal,/u,
      imports: ["import admin from './admin';", "import legal from './legal';"],
      localeContains: [] as string[],
      name: 'inserts before lex-larger first import (new entry at top of imports)',
      pageContains: [] as string[],
      route: 'admin',
      seed: [
        "import legal from './legal';",
        '',
        'export default {',
        '  legal,',
        '};',
        '',
      ],
    },
    {
      blockPattern: /legal,[ \t]*\n[ \t]*zone,/u,
      imports: [
        "import admin from './admin';",
        "import legal from './legal';",
        "import zone from './zone';",
      ],
      localeContains: [] as string[],
      name: 'appends after lex-smaller last import (new entry at bottom of imports)',
      pageContains: [] as string[],
      route: 'zone',
      seed: [
        "import admin from './admin';",
        "import legal from './legal';",
        '',
        'export default {',
        '  admin,',
        '  legal,',
        '};',
        '',
      ],
    },
  ])(
    '$name',
    ({blockPattern, imports, localeContains, pageContains, route, seed}) => {
      const barrelPath = seedLocaleBarrel(sandbox.root, seed.join('\n'));

      const result = scaffold(sandbox.root, [
        route,
        '--group',
        '_session',
        '--i18n',
      ]);

      expect(result.exit).toBe(0);

      const after = readFileSync(barrelPath, 'utf8');
      const importLines = after
        .split('\n')
        .filter((line) => /^import\s/u.test(line));
      expect(importLines).toEqual(imports);

      // Default-export block updated. `[ \t]*\n[ \t]*` (not `\s*\n\s*`, whose
      // `\s` already matches `\n` and overlaps with the literal that follows)
      // avoids sonarjs/super-linear-regex's overlapping-quantifier shape.
      expect(after).toMatch(blockPattern);

      const localeFile = path.join(
        sandbox.root,
        'app',
        'languages',
        'en',
        'pages',
        `${route}.ts`
      );
      expect(existsSync(localeFile)).toBe(true);

      for (const fragment of localeContains) {
        expect(readFileSync(localeFile, 'utf8')).toContain(fragment);
      }

      for (const fragment of pageContains) {
        expect(
          readFileSync(
            path.join(sandbox.root, 'app', 'pages', route, 'page.tsx'),
            'utf8'
          )
        ).toContain(fragment);
      }
    }
  );
});
