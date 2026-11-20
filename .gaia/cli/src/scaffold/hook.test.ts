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
import {execGaiaGit} from '../util/git-env.js';
import {
  writeBuiltinDescriptor,
  writeFrontendRegistry,
} from '../util/package-fixture.js';
import {run} from './hook.js';

type Sandbox = {
  cleanup: () => void;
  repoRoot: string;
};

const setupSandbox = (): Sandbox => {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-scaffold-hook-'));
  writeFrontendRegistry(repoRoot);

  return {
    cleanup: () => {
      rmSync(repoRoot, {force: true, recursive: true});
    },
    repoRoot,
  };
};

const read = (filePath: string): string => readFileSync(filePath, 'utf8');

const captureStdout = (): {restore: () => void; written: string[]} => {
  const written: string[] = [];
  const original = process.stdout.write.bind(process.stdout);
  const spy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown): boolean => {
      written.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    restore: () => {
      spy.mockRestore();
      // restore original binding to be safe across tests
      process.stdout.write = original;
    },
    written,
  };
};

const captureStderr = (): {restore: () => void; written: string[]} => {
  const written: string[] = [];
  const original = process.stderr.write.bind(process.stderr);
  const spy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown): boolean => {
      written.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    restore: () => {
      spy.mockRestore();
      process.stderr.write = original;
    },
    written,
  };
};

describe('gaia scaffold hook', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('emits hook + test for a bare name', () => {
    const stdout = captureStdout();

    try {
      const code = run(['useFoo'], {repoRoot: sandbox.repoRoot});

      expect(code).toBe(0);
    } finally {
      stdout.restore();
    }

    const hookPath = path.join(sandbox.repoRoot, 'app/hooks/use-foo.ts');
    const testPath = path.join(
      sandbox.repoRoot,
      'app/hooks/tests/use-foo.test.ts'
    );

    expect(read(hookPath)).toBe(
      [
        'export const useFoo = (): void => {',
        '  // Write the body of useFoo here.',
        '};',
        '',
      ].join('\n')
    );

    expect(read(testPath)).toBe(
      [
        "import {describe, expect, test} from 'vitest';",
        "import {renderHook} from 'vitest-browser-react';",
        "import {useFoo} from '../use-foo';",
        '',
        "describe('useFoo', () => {",
        "  test('renders without crashing', async () => {",
        '    await expect(renderHook(() => useFoo())).resolves.toBeDefined();',
        '  });',
        '});',
        '',
      ].join('\n')
    );
  });

  describe('hook --params and --returns render typed signatures', () => {
    test.each([
      {
        args: ['useFoo', '--params', 'id:string,count:number'],
        hookContains:
          'export const useFoo = (id: string, count: number): void => {',
        name: 'renders typed params from --params',
        testContains: ["renderHook(() => useFoo('', 0))"],
      },
      {
        args: ['useFoo', '--returns', 'string'],
        hookContains: 'export const useFoo = (): string => {',
        name: 'renders return-type annotation from --returns',
        testContains: [] as string[],
      },
      {
        args: ['useFoo', '--params', 'id:string', '--returns', 'boolean'],
        hookContains: 'export const useFoo = (id: string): boolean => {',
        name: 'combines --params and --returns',
        testContains: [] as string[],
      },
    ])('$name', ({args, hookContains, testContains}) => {
      const stdout = captureStdout();

      try {
        expect(run(args, {repoRoot: sandbox.repoRoot})).toBe(0);
      } finally {
        stdout.restore();
      }

      expect(
        read(path.join(sandbox.repoRoot, 'app/hooks/use-foo.ts'))
      ).toContain(hookContains);

      for (const fragment of testContains) {
        expect(
          read(path.join(sandbox.repoRoot, 'app/hooks/tests/use-foo.test.ts'))
        ).toContain(fragment);
      }
    });
  });

  describe('hook file naming follows the kebab convention', () => {
    test.each([
      {
        absent: [] as string[],
        contains: {
          'app/hooks/tests/use-toggle.test.ts': [
            "import {useToggle} from '../use-toggle';",
            'renderHook(() => useToggle())',
          ],
          'app/hooks/use-toggle.ts': ['export const useToggle = (): void => {'],
        },
        exists: [] as string[],
        name: 'a kebab name emits a kebab file exporting the camelCase hook',
        names: ['use-toggle'],
      },
      {
        absent: ['app/hooks/useCounter.ts'],
        contains: {
          'app/hooks/tests/use-counter.test.ts': ["from '../use-counter'"],
          'app/hooks/use-counter.ts': [
            'export const useCounter = (): void => {',
          ],
        },
        exists: ['app/hooks/use-toggle-open.ts'],
        name: 'a camelCase name emits the kebab file name for the same hook',
        names: ['useCounter', 'useToggleOpen'],
      },
    ])('$name', ({absent, contains, exists, names}) => {
      const stdout = captureStdout();

      try {
        for (const hookName of names) {
          expect(run([hookName], {repoRoot: sandbox.repoRoot})).toBe(0);
        }
      } finally {
        stdout.restore();
      }

      for (const [file, fragments] of Object.entries(contains)) {
        for (const fragment of fragments) {
          expect(read(path.join(sandbox.repoRoot, file))).toContain(fragment);
        }
      }

      for (const file of exists) {
        expect(existsSync(path.join(sandbox.repoRoot, file))).toBe(true);
      }

      for (const file of absent) {
        expect(existsSync(path.join(sandbox.repoRoot, file))).toBe(false);
      }
    });
  });

  describe('hook rejects a bad name or flag', () => {
    test.each([
      {
        args: ['foo'],
        code: 'invalid_hook_name',
        name: 'rejects names that do not start with `use`',
      },
      {
        // `usefoo` is lowercase after the prefix; must be `useF...`.
        args: ['usefoo'],
        code: 'invalid_hook_name',
        name: 'rejects names that start with `use` but are not camelCase',
      },
      ...['use_toggle', 'Usetoggle', 'use-', 'use--toggle', 'use-Toggle'].map(
        (invalidName) => ({
          args: [invalidName],
          code: 'invalid_hook_name',
          name: `rejects the invalid name ${invalidName} and writes nothing`,
        })
      ),
      {
        args: [] as string[],
        code: 'missing_argument',
        name: 'rejects when no name is supplied',
      },
      {
        args: ['useFoo', '--bogus'],
        code: 'invalid_flag',
        name: 'rejects unknown flags',
      },
    ])('$name', ({args, code}) => {
      const stderr = captureStderr();

      try {
        expect(run(args, {repoRoot: sandbox.repoRoot})).toBe(1);
      } finally {
        stderr.restore();
      }

      const payload = JSON.parse(stderr.written.join('').trim()) as {
        code: string;
      };

      expect(payload.code).toBe(code);
      expect(existsSync(path.join(sandbox.repoRoot, 'app'))).toBe(false);
    });
  });

  test('is idempotent: second invocation reports skipped', () => {
    const stdoutA = captureStdout();

    try {
      run(['useFoo'], {repoRoot: sandbox.repoRoot});
    } finally {
      stdoutA.restore();
    }

    const stdoutB = captureStdout();
    let code = -1;

    try {
      code = run(['useFoo', '--json'], {repoRoot: sandbox.repoRoot});
    } finally {
      stdoutB.restore();
    }

    expect(code).toBe(0);
    const payload = JSON.parse(stdoutB.written.join('').trim()) as {
      edited: string[];
      skipped: string[];
      written: string[];
    };

    expect(payload.written).toEqual([]);
    expect(payload.edited).toEqual([]);
    expect(payload.skipped).toHaveLength(2);
  });

  test('refuses to overwrite a customized file', () => {
    const hookPath = path.join(sandbox.repoRoot, 'app/hooks/use-foo.ts');
    const stdoutA = captureStdout();

    try {
      run(['useFoo'], {repoRoot: sandbox.repoRoot});
    } finally {
      stdoutA.restore();
    }
    // user customizes the file
    writeFileSync(hookPath, '// hand-edited\n', 'utf8');

    const stderr = captureStderr();
    let code = -1;

    try {
      code = run(['useFoo'], {repoRoot: sandbox.repoRoot});
    } finally {
      stderr.restore();
    }

    expect(code).toBe(11);
    const payload = JSON.parse(stderr.written.join('').trim()) as {
      code: string;
    };

    expect(payload.code).toBe('scaffold_failed');
    // original customization survives
    expect(read(hookPath)).toBe('// hand-edited\n');
  });

  test('--json prints a single ScaffoldResult line on stdout', () => {
    const stdout = captureStdout();
    let code = -1;

    try {
      code = run(['useFoo', '--json'], {repoRoot: sandbox.repoRoot});
    } finally {
      stdout.restore();
    }

    expect(code).toBe(0);
    const raw = stdout.written.join('');
    expect(raw.endsWith('\n')).toBe(true);
    const lines = raw.trim().split('\n');
    expect(lines).toHaveLength(1);
    const payload = JSON.parse(lines[0] ?? '') as {
      edited: string[];
      skipped: string[];
      written: string[];
    };

    expect(payload.written).toHaveLength(2);
    expect(payload.edited).toEqual([]);
    expect(payload.skipped).toEqual([]);

    for (const file of payload.written) {
      expect(path.isAbsolute(file)).toBe(true);
    }
  });
});

/**
 * Root resolution when the caller passes no `repoRoot`. Every test above
 * supplies one, so the default path -- the only path the shipped binary ever
 * takes -- had no coverage at all, and a refusal added to it reached the
 * release harness before anything caught it.
 */
describe('gaia scaffold hook root resolution', () => {
  let cwdBefore: string;
  let scratch: string[];

  beforeEach(() => {
    cwdBefore = process.cwd();
    scratch = [];
  });

  afterEach(() => {
    process.chdir(cwdBefore);

    for (const dir of scratch) {
      rmSync(dir, {force: true, recursive: true});
    }
  });

  // `os.tmpdir()` is a symlink on macOS, and `process.cwd()` reports the
  // physically resolved path, so the expectations below only line up against a
  // realpath'd root.
  const newScratchDir = (): string => {
    const dir = realpathSync(
      mkdtempSync(path.join(tmpdir(), 'gaia-hook-root-'))
    );
    writeBuiltinDescriptor(dir);
    scratch.push(dir);

    return dir;
  };

  describe('hook resolves the package root', () => {
    test.each([
      {
        absent: [] as string[],
        exists: [
          'apps/web/app/hooks/use-foo.ts',
          'apps/web/app/hooks/tests/use-foo.test.ts',
        ],
        hookName: 'useFoo',
        name: 'scaffolds under the built-in frontend package outside a git repository',
        prepare: (root: string): string => root,
      },
      {
        absent: [
          'packages/inner/app/hooks/use-bar.ts',
          'packages/inner/apps/web',
        ],
        exists: ['apps/web/app/hooks/use-bar.ts'],
        hookName: 'useBar',
        name: 'scaffolds into the working tree root, not the calling subdirectory',
        prepare: (root: string): string => {
          // Through the chokepoint, not a bare `execFileSync('git', ...)`: an
          // ambient GIT_DIR would send `git init` at the directory that
          // variable names, leaving `root` without a `.git` and this
          // assertion measuring nothing.
          execGaiaGit(['init', '-q', '-b', 'main'], root);
          const inner = path.join(root, 'packages', 'inner');
          mkdirSync(inner, {recursive: true});

          return inner;
        },
      },
    ])('$name', ({absent, exists, hookName, prepare}) => {
      const root = newScratchDir();
      const stdout = captureStdout();
      let code = -1;

      process.chdir(prepare(root));

      try {
        code = run([hookName]);
      } finally {
        stdout.restore();
      }

      expect(code).toBe(0);

      for (const file of exists) {
        expect(existsSync(path.join(root, file))).toBe(true);
      }

      for (const file of absent) {
        expect(existsSync(path.join(root, file))).toBe(false);
      }
    });
  });
});
