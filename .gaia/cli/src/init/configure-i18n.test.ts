import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
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
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {run} from './configure-i18n.js';
import {readState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const LANGUAGES_INDEX_TEMPLATE = `import en from './en';

export const LANGUAGES = ['en'];

export type Language = 'en';

export default {en} as const;
`;

const I18N_TEMPLATE = `import resources, {LANGUAGES} from '~/languages';

const i18n = {
  defaultNS: 'common',
  fallbackLng: 'en',
  fallbackNS: ['common'],
  resources,
  supportedLngs: LANGUAGES,
};

export default i18n;
`;

const writeLanguageTree = (root: string, code: string): void => {
  const tree = path.join(root, 'app', 'languages', code);
  mkdirSync(tree, {recursive: true});
  writeFileSync(path.join(tree, 'index.ts'), 'export default {};\n', 'utf8');
};

const readLanguagesIndex = (root: string): string =>
  readFileSync(path.join(root, 'app', 'languages', 'index.ts'), 'utf8');

// The locale codes languages/index.ts imports whose tree is missing on disk.
const importsWithoutTree = (root: string): string[] =>
  [...readLanguagesIndex(root).matchAll(/^import \w+ from '\.\/([\w-]+)';$/gmu)]
    .map((match) => match[1] ?? '')
    .filter((code) => !existsSync(path.join(root, 'app', 'languages', code)));

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-configure-i18n-'));
  writeFrontendRegistry(root);
  writeLanguageTree(root, 'en');
  writeFileSync(
    path.join(root, 'app', 'languages', 'index.ts'),
    LANGUAGES_INDEX_TEMPLATE,
    'utf8'
  );
  writeFileSync(path.join(root, 'app', 'i18n.ts'), I18N_TEMPLATE, 'utf8');

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

describe('init configure-i18n', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test.each([
    ['the default locale only', 'en'],
    ['one added locale', 'en,es'],
    ['two added locales', 'en,es,ja'],
  ])(
    '--strip false with %s imports only language trees that exist',
    (_label, locales) => {
      sandbox = setupSandbox();

      const exit = run(['--locales', locales, '--strip', 'false'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      expect(importsWithoutTree(sandbox.root)).toEqual([]);
      expect(readLanguagesIndex(sandbox.root)).toContain(
        "export const LANGUAGES = ['en'];"
      );

      const state = readState(sandbox.root);
      expect(state.completed_steps).toContain('configure-i18n');
      expect(state.step_args['configure-i18n']).toEqual({
        locales: locales.split(','),
        strip: false,
      });
    }
  );

  test('a primary locale with no tree yet keeps the index valid and sets the fallback', () => {
    sandbox = setupSandbox();
    const before = readLanguagesIndex(sandbox.root);

    const exit = run(['--locales', 'fr', '--strip', 'false'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    expect(readLanguagesIndex(sandbox.root)).toBe(before);
    expect(
      readFileSync(path.join(sandbox.root, 'app', 'i18n.ts'), 'utf8')
    ).toContain("fallbackLng: 'fr'");
  });

  test('drops a registered locale that was not picked once a picked one is registered', () => {
    sandbox = setupSandbox();
    writeLanguageTree(sandbox.root, 'fr');
    writeFileSync(
      path.join(sandbox.root, 'app', 'languages', 'index.ts'),
      `import en from './en';
import fr from './fr';

export const LANGUAGES = ['en', 'fr'];

export type Language = 'en' | 'fr';

export default {en, fr} as const;
`,
      'utf8'
    );

    const exit = run(['--locales', 'fr', '--strip', 'false'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    expect(readLanguagesIndex(sandbox.root)).toBe(`import fr from './fr';

export const LANGUAGES = ['fr'];

export type Language = 'fr';

export default {fr} as const;
`);
  });

  test('--strip true skips edits but records state', () => {
    sandbox = setupSandbox();
    const before = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'index.ts'),
      'utf8'
    );

    const exit = run(['--locales', 'en', '--strip', 'true'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const after = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'index.ts'),
      'utf8'
    );
    expect(after).toBe(before);

    const state = readState(sandbox.root);
    expect(state.step_args['configure-i18n']).toEqual({
      locales: ['en'],
      strip: true,
    });
  });

  test('idempotent: re-running with same args is a no-op on file content', () => {
    sandbox = setupSandbox();
    run(['--locales', 'en,es', '--strip', 'false'], {cwd: sandbox.root});
    const first = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'index.ts'),
      'utf8'
    );

    const second = run(['--locales', 'en,es', '--strip', 'false'], {
      cwd: sandbox.root,
    });
    expect(second).toBe(0);
    const after = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'index.ts'),
      'utf8'
    );
    expect(after).toBe(first);
  });

  test('exit 1 on missing flags', () => {
    sandbox = setupSandbox();
    expect(run(['--locales', 'en'], {cwd: sandbox.root})).toBe(1);
    expect(run(['--strip', 'true'], {cwd: sandbox.root})).toBe(1);
  });

  test('exit 1 on invalid --strip value', () => {
    sandbox = setupSandbox();
    const exit = run(['--locales', 'en', '--strip', 'yes'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--strip must be');
  });

  test('exit 1 on invalid --locales list', () => {
    sandbox = setupSandbox();
    const exit = run(['--locales', '???', '--strip', 'false'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('invalid --locales');
  });
});
