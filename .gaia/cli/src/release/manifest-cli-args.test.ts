/**
 * The check/emit execution tests (manifest content, `--check` reporting, the
 * answer gate) live in `manifest-cli.test.ts`.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './manifest-cli.js';

type Sandbox = {
  cleanup: () => void;
  commit: (message: string, files: Record<string, string>) => string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-manifest-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});

  const commit = (message: string, files: Record<string, string>): string => {
    for (const [relativePath, contents] of Object.entries(files)) {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    }
    execFileSync('git', ['add', '-A'], {cwd: root});
    execFileSync('git', ['commit', '-q', '-m', message], {cwd: root});

    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim();
  };

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commit,
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

const GENERATED_AT = '2026-05-07T00:00:00.000Z';

type GrammarCase = {
  argv: string[];
  message: string;
  name: string;
  notMessages: string[];
  version: string;
};

// Every flag in an `invalid_arguments` row is known, so an unknown-flag
// refusal there is the wrong reason.
const invalidArguments = (label: string, argv: string[]): GrammarCase => ({
  argv,
  message: 'invalid_arguments',
  name: `rejects ${label}`,
  notMessages: ['unknown flag'],
  version: '1.0.0',
});

const withhold = (target: string, ...rest: string[]): string[] => [
  '--withhold',
  target,
  ...rest,
];

describe('run (CLI flag grammar)', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test.each<GrammarCase>([
    {
      argv: ['--bogus'],
      message: 'unknown flag',
      name: 'rejects unknown flags',
      notMessages: [],
      version: '0.0.1',
    },
    ...[
      'toString',
      'valueOf',
      'constructor',
      'hasOwnProperty',
      '__proto__',
    ].map((token) => ({
      argv: [token],
      message: 'unknown flag',
      name: `rejects the prototype-member token ${token} as an unknown flag`,
      notMessages: [],
      version: '0.0.1',
    })),
    {
      argv: ['--check', '--out', 'foo.json'],
      message: 'incompatible',
      name: '--check is incompatible with --out',
      notMessages: [],
      version: '1.0.0',
    },
    {
      argv: ['--json'],
      message: '--json requires --check',
      name: '--json requires --check',
      notMessages: [],
      version: '1.0.0',
    },
    invalidArguments('--check with --ship', [
      '--check',
      '--ship',
      'app/new.ts',
    ]),
    invalidArguments('--check with --allow-undecided', [
      '--check',
      '--allow-undecided',
    ]),
    invalidArguments('--check with --withhold', [
      '--check',
      ...withhold('app/new.ts', '--category', '1', '--reason', 'r'),
    ]),
    invalidArguments('--category with no open --withhold', ['--category', '1']),
    invalidArguments('--reason with no open --withhold', ['--reason', 'r']),
    invalidArguments(
      'a --withhold with no --category',
      withhold('app/new.ts', '--reason', 'r')
    ),
    invalidArguments(
      'a --withhold with no --reason',
      withhold('app/new.ts', '--category', '1')
    ),
    invalidArguments(
      'two --category on one --withhold',
      withhold(
        'app/new.ts',
        '--category',
        '1',
        '--category',
        '2',
        '--reason',
        'r'
      )
    ),
    invalidArguments(
      'a non-numeric --category',
      withhold('app/new.ts', '--category', 'one', '--reason', 'r')
    ),
    invalidArguments('--check with --withdraw', [
      '--check',
      '--withdraw',
      'app/foo.ts',
      '--category',
      '1',
      '--reason',
      'r',
    ]),
    invalidArguments('a --withdraw with no --category', [
      '--withdraw',
      'app/foo.ts',
      '--reason',
      'r',
    ]),
    invalidArguments('a --withdraw with no --reason', [
      '--withdraw',
      'app/foo.ts',
      '--category',
      '1',
    ]),
    invalidArguments('a --withdraw left open by the next --withhold', [
      '--withdraw',
      'app/foo.ts',
      ...withhold('app/new.ts', '--category', '1', '--reason', 'r'),
    ]),
  ])('$name', ({argv, message, notMessages, version}) => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': `${version}\n`,
    });

    const exit = run(argv, {cwd: sandbox.root, generatedAt: GENERATED_AT});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(message);

    for (const unwanted of notMessages) {
      expect(stdio.errors.join('')).not.toContain(unwanted);
    }
  });
});
