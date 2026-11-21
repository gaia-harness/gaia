/**
 * Exercises the determinism classifier AST helper
 * (`.gaia/scripts/classifier/classify-determinism.mjs`), which labels a
 * touched source file STRICT (deterministic) or
 * EMERGENT (clock-/entropy-/I-O-bound or tree-dependent). The label picks the
 * worthiness judgment arm and evidence. Path scopes the candidate set; content decides. The bias is
 * deliberate: err EMERGENT. Over-strict is the worse failure.
 *
 * The helper ships to adopters (manifest `owned`, run by shipped hooks); this
 * test is maintainer-only because `.gaia/cli/src` is release-excluded.
 *
 * The helper resolves `typescript` from `node_modules`; this `.gaia/cli`
 * workspace carries its own `typescript` devDependency, so the test runner
 * can exec it. Synthetic fixtures are fed through `--stdin` (the path
 * argument names the file identity for path scoping and `.ts`-vs-`.tsx`
 * script kind; stdin supplies the bytes). The three named real fixtures are
 * classified from disk by repo-relative path.
 */
import {afterAll, beforeAll, describe, expect, test} from 'vitest';
import {execFileSync, spawnSync} from 'node:child_process';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);
const HELPER = path.join(
  REPO_ROOT,
  '.gaia/scripts/classifier/classify-determinism.mjs'
);

// The helper resolves `typescript` by walking up from its own location to the
// repo-root node_modules. The GAIA: CLI Tests workflow installs deps only in
// `.gaia/cli`, so typescript lives there, not at the (uninstalled) repo root.
// Expose `.gaia/cli/node_modules` via NODE_PATH so the exec'd helper resolves
// typescript whether or not the repo root is installed.
const HELPER_ENV = {
  ...process.env,
  NODE_PATH: path.join(REPO_ROOT, '.gaia/cli/node_modules'),
};

type Classification = {
  classification: 'emergent' | 'route' | 'strict';
  file: string;
  reasons: string[];
};

// The classifier reads the package registry from its working directory, so the
// suite runs it from a scratch tree with no `.gaia/packages.json`: the built-in
// default (the app at `apps/web/`), the 2.0.0 layout, whatever shape the real
// checkout is in. The package descriptor is copied in from the real checkout;
// the two util sources come from `fixtures/`, frozen copies of helpers the
// template no longer ships, so the regressions they pin keep a subject.
let FIXTURE_ROOT = '';

const FIXTURE_SOURCES = path.join(import.meta.dirname, 'fixtures');

// Where a real app file lives in this checkout: under `apps/web/` once the app
// has moved, at the repo root before.
const realAppFile = (frontendRelativePath: string): string => {
  const moved = path.join(REPO_ROOT, frontendRelativePath);

  return existsSync(moved) ? moved : (
      path.join(REPO_ROOT, frontendRelativePath.replace(/^frontend\//, ''))
    );
};

beforeAll(() => {
  FIXTURE_ROOT = mkdtempSync(path.join(os.tmpdir(), 'classify-determinism-'));

  for (const [file, source] of [
    [
      'apps/web/app/utils/date.ts',
      path.join(FIXTURE_SOURCES, 'date.ts.fixture'),
    ],
    [
      'apps/web/app/utils/string.ts',
      path.join(FIXTURE_SOURCES, 'string.ts.fixture'),
    ],
    ['apps/web/gaia.package.json', realAppFile('apps/web/gaia.package.json')],
  ] as const) {
    mkdirSync(path.join(FIXTURE_ROOT, path.dirname(file)), {recursive: true});
    copyFileSync(source, path.join(FIXTURE_ROOT, file));
  }
});

afterAll(() => {
  rmSync(FIXTURE_ROOT, {force: true, recursive: true});
});

// Classify a real file on disk by its repo-relative path.
const classifyFile = (repoRelativePath: string): Classification => {
  const out = execFileSync('node', [HELPER, repoRelativePath], {
    cwd: FIXTURE_ROOT,
    encoding: 'utf8',
    env: HELPER_ENV,
  });

  return JSON.parse(out) as Classification;
};

// Classify synthetic source bytes fed through stdin. `fileIdentity` is the
// repo-relative path used for path scoping and script-kind selection.
const classifySource = (
  fileIdentity: string,
  source: string
): Classification => {
  const out = execFileSync('node', [HELPER, fileIdentity, '--stdin'], {
    cwd: FIXTURE_ROOT,
    encoding: 'utf8',
    env: HELPER_ENV,
    input: source,
  });

  return JSON.parse(out) as Classification;
};

// Run the classifier in a scratch tree carrying its own registry and
// descriptor files, written as literals so the case outlives the registry
// flip in the real checkout.
const withTree = <T>(
  files: Record<string, string>,
  run: (cwd: string) => T
): T => {
  const tree = mkdtempSync(path.join(os.tmpdir(), 'classify-packages-'));

  try {
    for (const [relative, content] of Object.entries(files)) {
      mkdirSync(path.join(tree, path.dirname(relative)), {recursive: true});
      writeFileSync(path.join(tree, relative), content);
    }

    return run(tree);
  } finally {
    rmSync(tree, {force: true, recursive: true});
  }
};

const descriptor = (strict: string[]): string =>
  JSON.stringify({
    globs: {
      dependencyManifests: ['package.json'],
      doctorConfigs: ['doctor.config.*'],
      emergentTests: ['app/**/*.test.ts'],
      preCommitSource: ['app/**'],
      tddStrictCandidates: strict,
      tddUnitTests: ['app/**/*.test.ts'],
    },
    name: 'web',
    schemaVersion: 1,
    wiki: {
      flowPaths: ['app/'],
      inventoryPaths: ['app/'],
      sourcePaths: ['app/'],
    },
  });

type SourceCase = {
  classification: Classification['classification'];
  file: string;
  name: string;
  reasons?: RegExp[];
  source: string;
};

// One test per row, titled with the full row name (`$name` would truncate).
const eachSourceCase = (cases: SourceCase[]): void => {
  test.each(cases.map((row) => [row.name, row] as const))(
    '%s',
    (_name, row) => {
      const result = classifySource(row.file, row.source);

      expect(result.classification).toBe(row.classification);

      for (const pattern of row.reasons ?? []) {
        expect(result.reasons.join(' ')).toMatch(pattern);
      }
    }
  );
};

const ADD_SOURCE =
  'export const add = (a: number, b: number): number => a + b;\n';

describe('classify-determinism', () => {
  test('emits the {file, classification, reasons} contract shape', () => {
    const result = classifySource(
      'apps/web/app/utils/example.ts',
      'export const add = (a: number, b: number): number => a + b;\n'
    );

    expect(result.file).toBe('apps/web/app/utils/example.ts');
    expect(result.classification).toBe('strict');
    expect(Array.isArray(result.reasons)).toBe(true);
  });

  describe('condition 1: path scoping', () => {
    eachSourceCase([
      {
        classification: 'emergent',
        file: 'apps/web/app/routes/_index.tsx',
        name: 'classifies a pure file outside the candidate paths EMERGENT',
        reasons: [/path/i],
        source: ADD_SOURCE,
      },
      {
        classification: 'emergent',
        file: 'apps/web/app/components/Foo/utils.tsx',
        name: 'classifies a .tsx file under app/components EMERGENT',
        source: ADD_SOURCE,
      },
      {
        classification: 'strict',
        file: 'apps/web/app/components/Foo/utils.ts',
        name: 'classifies a pure .ts file under app/components STRICT',
        source: ADD_SOURCE,
      },
      {
        classification: 'strict',
        file: 'apps/web/app/services/example/parse.ts',
        name: 'classifies a pure file under app/services STRICT',
        source:
          'export const toUpper = (s: string): string => s.toUpperCase();\n',
      },
    ]);
  });

  describe('condition 2: module-reachable non-determinism', () => {
    eachSourceCase([
      {
        classification: 'emergent',
        file: 'apps/web/app/utils/date.ts',
        name: 'classifies a default-parameter new Date() EMERGENT (the FI-3 fix)',
        reasons: [/new Date/],
        source:
          "import {format} from 'date-fns';\n" +
          "export const formatMY = (date = new Date()): string => format(date, 'MM/yy');\n",
      },
      {
        classification: 'emergent',
        file: 'apps/web/app/utils/clock.ts',
        name: 'classifies a module-level new Date() constant EMERGENT',
        source:
          'const TODAY = new Date();\nexport const year = (): number => TODAY.getFullYear();\n',
      },
      {
        classification: 'emergent',
        file: 'apps/web/app/utils/id.ts',
        name: 'classifies a class-field Math.random() initializer EMERGENT',
        reasons: [/Math\.random/],
        source: 'export class Id {\n  value = Math.random();\n}\n',
      },
      {
        classification: 'emergent',
        file: 'apps/web/app/utils/now.ts',
        name: 'classifies a Date.now() call EMERGENT',
        source: 'export const stamp = (): number => Date.now();\n',
      },
      {
        classification: 'emergent',
        file: 'apps/web/app/utils/token.ts',
        name: 'classifies a crypto usage EMERGENT',
        source: 'export const token = (): string => crypto.randomUUID();\n',
      },
      {
        classification: 'emergent',
        file: 'apps/web/app/utils/config.ts',
        name: 'classifies a top-level await EMERGENT',
        source:
          "const data = await import('./other');\nexport const value = data;\n",
      },
    ]);
  });

  describe('condition 3: hook call-surface rule', () => {
    eachSourceCase([
      {
        classification: 'emergent',
        file: 'apps/web/app/hooks/useThing.ts',
        name: 'classifies a hook reading a react-router runtime hook EMERGENT',
        reasons: [/useNavigate/],
        source:
          "import {useNavigate} from 'react-router';\n" +
          'export const useThing = () => {\n  const navigate = useNavigate();\n  return navigate;\n};\n',
      },
      {
        classification: 'emergent',
        file: 'apps/web/app/hooks/useSize.ts',
        name: 'classifies a hook calling a DOM-layout API EMERGENT',
        source:
          'export const useSize = (el: HTMLElement) => {\n' +
          '  return el.getBoundingClientRect();\n};\n',
      },
      {
        classification: 'strict',
        file: 'apps/web/app/hooks/useToggle.ts',
        name: 'classifies a useState/useMemo-only hook STRICT',
        source:
          "import {useState, useCallback} from 'react';\n" +
          'export const useToggle = () => {\n' +
          '  const [on, setOn] = useState(false);\n' +
          '  const toggle = useCallback(() => setOn((v) => !v), []);\n' +
          '  return {on, toggle};\n};\n',
      },
      {
        classification: 'strict',
        file: 'apps/web/app/hooks/useMedia.ts',
        name: 'classifies a hook using only the allowlisted matchMedia STRICT',
        source:
          "import {useState} from 'react';\n" +
          'export const useMedia = (q: string) => {\n' +
          '  const [match] = useState(() => globalThis.matchMedia(q).matches);\n' +
          '  return match;\n};\n',
      },
      {
        // A hook is a hook even under app/utils/**: judged by its call
        // surface, and a plain useState hook is STRICT.
        classification: 'strict',
        file: 'apps/web/app/utils/useCounter.ts',
        name: 'routes a use* export under app/utils through condition 3, not 2/4',
        source:
          "import {useState} from 'react';\n" +
          'export const useCounter = () => {\n' +
          '  const [n, setN] = useState(0);\n' +
          '  return {n, inc: () => setN((v) => v + 1)};\n};\n',
      },
      {
        classification: 'emergent',
        file: 'apps/web/app/hooks/useBattery.ts',
        name: 'classifies a hook calling a DOM API absent from the allowlist EMERGENT',
        reasons: [/unknown DOM API|allowlist/i],
        source:
          'export const useBattery = () => {\n' +
          '  return globalThis.navigator.getBattery();\n};\n',
      },
    ]);
  });

  describe('condition 4: no public async I/O export', () => {
    eachSourceCase([
      {
        classification: 'emergent',
        file: 'apps/web/app/services/example/load.ts',
        name: 'classifies a public async export wrapping fetch EMERGENT',
        source:
          'export const load = async (url: string): Promise<Response> =>\n' +
          '  fetch(url);\n',
      },
      {
        classification: 'emergent',
        file: 'apps/web/app/services/example/sleep.ts',
        name: 'classifies a public async setTimeout-as-sleep export EMERGENT',
        source:
          'export const sleep = async (ms: number): Promise<void> =>\n' +
          '  new Promise((resolve) => setTimeout(resolve, ms));\n',
      },
    ]);
  });

  describe('route tests', () => {
    const testSource =
      "import {expect, test} from 'vitest';\ntest('x', () => { expect(1).toBe(1); });\n";

    eachSourceCase([
      {
        classification: 'route',
        file: 'apps/web/app/route-tests/orders/tests/refuses-anonymous.test.ts',
        name: 'classifies a test in a route-tests tests folder as ROUTE with a reason',
        reasons: [/route test/],
        source: testSource,
      },
      ...[
        'apps/web/app/route-tests/orders/refuses.test.ts',
        'apps/web/app/route-tests/orders/tests/refuses.spec.ts',
        'apps/web/app/other/orders/tests/refuses.test.ts',
      ].map((candidatePath) => ({
        classification: 'emergent' as const,
        file: candidatePath,
        name: `does not classify ${candidatePath} as ROUTE`,
        source: testSource,
      })),
    ]);
  });

  describe('story files', () => {
    const STORY_REASON =
      /story file: a \*\.stories\.tsx is emergent regardless of path/;
    const pureSource = 'export const double = (n: number): number => n * 2;\n';

    eachSourceCase([
      ...[
        'apps/web/app/utils/tests/notify.stories.tsx',
        'apps/web/app/services/api/tests/client.stories.tsx',
        'apps/web/app/hooks/tests/use-thing.stories.tsx',
        'apps/web/app/components/Foo/tests/index.stories.tsx',
      ].map((storyPath) => ({
        classification: 'emergent' as const,
        file: storyPath,
        name: `classifies ${storyPath} EMERGENT with the story reason`,
        reasons: [STORY_REASON],
        source: pureSource,
      })),
      {
        classification: 'emergent',
        file: 'apps/web/app/utils/tests/pure.stories.ts',
        name: 'classifies a .stories.ts file EMERGENT',
        reasons: [STORY_REASON],
        source: pureSource,
      },
    ]);

    test('classifies a pure story under a strict-candidate folder EMERGENT while the same content in a .ts file is STRICT', () => {
      const asStory = classifySource(
        'apps/web/app/utils/tests/pure.stories.tsx',
        pureSource
      );
      const asModule = classifySource('apps/web/app/utils/pure.ts', pureSource);

      expect(asStory.classification).toBe('emergent');
      expect(asModule.classification).toBe('strict');
    });
  });

  describe('file-granularity limitation', () => {
    test('classifies a mixed pure-export/impure-constant file whole-file EMERGENT', () => {
      const result = classifySource(
        'apps/web/app/utils/mixed.ts',
        'const SEED = Math.random();\n' +
          'export const pure = (a: number, b: number): number => a + b;\n' +
          'export const tainted = (): number => SEED;\n'
      );

      expect(result.classification).toBe('emergent');
    });
  });

  describe('named regression fixtures (real files on disk)', () => {
    test('classifies apps/web/app/utils/date.ts EMERGENT (default-param new Date())', () => {
      const result = classifyFile('apps/web/app/utils/date.ts');

      expect(result.classification).toBe('emergent');
    });

    test('classifies apps/web/app/utils/string.ts STRICT (pure string helpers)', () => {
      const result = classifyFile('apps/web/app/utils/string.ts');

      expect(result.classification).toBe('strict');
    });
  });

  describe('package scope (descriptor-driven candidate globs)', () => {
    const PURE =
      'export const add = (a: number, b: number): number => a + b;\n';

    test('classifies the same pure file at the unmoved root path EMERGENT, naming the descriptor prefixes', () => {
      const result = classifySource('app/utils/example.ts', PURE);

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toContain(
        'path not in apps/web/app/utils/**'
      );
      expect(result.reasons.join(' ')).not.toContain('path not in app/utils');
    });

    const run = (cwd: string, target: string) =>
      spawnSync('node', [HELPER, target, '--stdin'], {
        cwd,
        encoding: 'utf8',
        env: HELPER_ENV,
        input: PURE,
      });

    const registryRows: {
      classification: string;
      files: Record<string, string>;
      name: string;
      reasonFragments: string[];
      target: string;
    }[] = [
      {
        classification: 'strict',
        files: {
          '.gaia/packages.json': '[{"name":"web","path":"."}]',
          'gaia.package.json': descriptor(['app/utils/**']),
        },
        name: "a literal path-'.' registry keeps today's layout: root app/utils is strict",
        reasonFragments: [],
        target: 'app/utils/x.ts',
      },
      {
        classification: 'emergent',
        files: {
          '.gaia/packages.json': '[{"name":"web","path":"apps/web"}]',
          'apps/web/gaia.package.json': descriptor(['nomatch/**']),
        },
        name: 'a descriptor whose strict globs match nothing classifies the same file emergent (the guard can fail)',
        reasonFragments: ['path not in apps/web/nomatch/**'],
        target: 'apps/web/app/utils/x.ts',
      },
      {
        classification: 'emergent',
        files: {'.gaia/packages.json': '[]'},
        name: 'an empty registry has no strict candidates, so a pure file classifies emergent',
        reasonFragments: [],
        target: 'apps/web/app/utils/x.ts',
      },
    ];

    test.each(registryRows.map((row) => [row.name, row] as const))(
      '%s',
      (_name, row) => {
        withTree(row.files, (cwd) => {
          const result = run(cwd, row.target);

          expect(result.status).toBe(0);
          const parsed = JSON.parse(result.stdout);

          expect(parsed.classification).toBe(row.classification);

          for (const fragment of row.reasonFragments) {
            expect(parsed.reasons.join(' ')).toContain(fragment);
          }
        });
      }
    );

    test.each(
      [
        {
          error: 'git checkout origin/main -- apps/web/gaia.package.json',
          files: {} as Record<string, string>,
          name: 'no registry and no descriptor exits 7 naming the restore step',
        },
        {
          error: /^gaia-packages: \.gaia\/packages\.json is malformed/,
          files: {'.gaia/packages.json': '{'},
          name: 'an unparseable registry exits 7 with {"error"} on stdout and classifies nothing',
        },
        {
          error: 'apps/web/gaia.package.json is missing',
          files: {'.gaia/packages.json': '[{"name":"web","path":"apps/web"}]'},
          name: 'a registered package with no descriptor exits 7 with {"error"} naming the descriptor',
        },
      ].map((row) => [row.name, row] as const)
    )('%s', (_name, row) => {
      withTree(row.files, (cwd) => {
        const result = run(cwd, 'apps/web/app/utils/x.ts');

        expect(result.status).toBe(7);
        const parsed = JSON.parse(result.stdout);

        expect(parsed.error).toMatch(row.error);
        expect(parsed.classification).toBeUndefined();
      });
    });
  });
});
