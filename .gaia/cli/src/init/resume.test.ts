/**
 * Mostly drives the resume orchestrator with stubbed step runners so we can
 * assert ordering + skip-if-complete + argv reconstruction without spinning
 * up real filesystem fixtures for each step.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {writeBuiltinDescriptor} from '../util/package-fixture.js';
import {argvFromStepArgs, run} from './resume.js';
import {STEP_ORDER, writeState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-resume-'));

  writeBuiltinDescriptor(root);

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

type StepArgsRow = [
  name: string,
  step: Parameters<typeof argvFromStepArgs>[0],
  saved: Parameters<typeof argvFromStepArgs>[1],
  expected: null | string[],
];

describe('argvFromStepArgs', () => {
  const stepArgsRows: StepArgsRow[] = [
    [
      'strip-branding argv from its title',
      'strip-branding',
      {title: 'Hello'},
      ['--title', 'Hello'],
    ],
    ['strip-branding argv is null without a title', 'strip-branding', {}, null],
    [
      'configure-i18n argv',
      'configure-i18n',
      {locales: ['en', 'es'], strip: false},
      ['--locales', 'en,es', '--strip', 'false'],
    ],
    [
      'configure-i18n argv is null for a bad locales value',
      'configure-i18n',
      {locales: 'bad'},
      null,
    ],
    [
      'configure-data-layer argv with every key',
      'configure-data-layer',
      {casing: 'camel', layer: 'acme', query: true},
      ['--casing', 'camel', '--query', 'true', '--layer', 'acme'],
    ],
    [
      'configure-data-layer argv round-trips null keys',
      'configure-data-layer',
      {casing: null, layer: null, query: false},
      ['--query', 'false'],
    ],
    [
      'configure-data-layer argv is null when nothing is saved',
      'configure-data-layer',
      {casing: null, layer: null, query: null},
      null,
    ],
    [
      'configure-data-layer argv is null for undefined args',
      'configure-data-layer',
      undefined,
      null,
    ],
    [
      'rename argv',
      'rename',
      {kebab: 'hello-world', title: 'Hello World'},
      ['--title', 'Hello World', '--kebab', 'hello-world'],
    ],
    ['wire-statusline argv', 'wire-statusline', {}, []],
    [
      'write-project-config argv with the required flag only',
      'write-project-config',
      {sandbox_recommended: true},
      ['--sandbox-recommended', 'true'],
    ],
    [
      'write-project-config argv with both flags',
      'write-project-config',
      {isolation_policy: 'always-worktree', sandbox_recommended: false},
      [
        '--sandbox-recommended',
        'false',
        '--isolation-policy',
        'always-worktree',
      ],
    ],
    [
      'write-project-config argv is null for empty saved args',
      'write-project-config',
      {},
      null,
    ],
    [
      'write-project-config argv is null for undefined saved args',
      'write-project-config',
      undefined,
      null,
    ],
    [
      'write-project-config argv is null for a non-boolean sandbox flag',
      'write-project-config',
      {sandbox_recommended: 'true'},
      null,
    ],
    [
      'write-project-config argv is null for a non-string policy',
      'write-project-config',
      {isolation_policy: 7, sandbox_recommended: true},
      null,
    ],
    ['finalize requires no args', 'finalize', undefined, []],
    [
      'returns null when saved args are missing for a non-finalize step',
      'strip-branding',
      undefined,
      null,
    ],
  ];

  test.each(stepArgsRows)(
    'reconstructs: %s',
    (_name, step, saved, expected) => {
      expect(argvFromStepArgs(step, saved)).toEqual(expected);
    }
  );

  test('STEP_ORDER places configure-data-layer right after configure-i18n', () => {
    expect(STEP_ORDER).toHaveLength(7);
    expect(STEP_ORDER.indexOf('configure-data-layer')).toBe(
      STEP_ORDER.indexOf('configure-i18n') + 1
    );
    expect(STEP_ORDER.indexOf('write-project-config')).toBe(5);
    expect(STEP_ORDER as readonly string[]).not.toContain(
      ['configure', 'automation'].join('-')
    );
  });
});

describe('init resume', () => {
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

  test('--from-step 4 skips steps 1-3 if marked complete; runs from step 4', async () => {
    sandbox = setupSandbox();
    writeState(sandbox.root, {
      completed_steps: [
        'strip-branding',
        'configure-i18n',
        'configure-data-layer',
      ],
      step_args: {
        'configure-data-layer': {casing: 'snake', layer: null, query: false},
        'configure-i18n': {locales: ['en'], strip: false},
        rename: {kebab: 'hello', title: 'Hello'},
        'strip-branding': {title: 'Hello'},
        'wire-statusline': {},
        'write-project-config': {sandbox_recommended: true},
      },
    });

    const calls: {argv: readonly string[]; step: string}[] = [];

    const stub = (step: string) => (argv: readonly string[]) => {
      calls.push({argv, step});

      return 0;
    };

    const exit = await run(['--from-step', '4'], {
      cwd: sandbox.root,
      runners: {
        'configure-data-layer': stub('configure-data-layer'),
        'configure-i18n': stub('configure-i18n'),
        finalize: stub('finalize'),
        rename: stub('rename'),
        'strip-branding': stub('strip-branding'),
        'wire-statusline': stub('wire-statusline'),
        'write-project-config': stub('write-project-config'),
      },
    });
    expect(exit).toBe(0);

    // the first three steps are before step 4, and ALSO marked
    // complete. They should not run regardless of skip-vs-from-step.
    expect(calls.map((c) => c.step)).toEqual([
      'rename',
      'wire-statusline',
      'write-project-config',
      'finalize',
    ]);
    expect(calls[0]?.argv).toEqual(['--title', 'Hello', '--kebab', 'hello']);
  });

  test('default --from-step 1 still skips already-complete steps', async () => {
    sandbox = setupSandbox();
    writeState(sandbox.root, {
      completed_steps: ['strip-branding'],
      step_args: {
        'configure-data-layer': {casing: 'snake', layer: null, query: false},
        'configure-i18n': {locales: ['en'], strip: true},
        rename: {kebab: 'x', title: 'X'},
        'strip-branding': {title: 'X'},
        'wire-statusline': {},
        'write-project-config': {sandbox_recommended: false},
      },
    });

    const ran: string[] = [];

    const stub = (step: string) => () => {
      ran.push(step);

      return 0;
    };

    const exit = await run([], {
      cwd: sandbox.root,
      runners: {
        'configure-data-layer': stub('configure-data-layer'),
        'configure-i18n': stub('configure-i18n'),
        finalize: stub('finalize'),
        rename: stub('rename'),
        'strip-branding': stub('strip-branding'),
        'wire-statusline': stub('wire-statusline'),
        'write-project-config': stub('write-project-config'),
      },
    });
    expect(exit).toBe(0);
    expect(ran).not.toContain('strip-branding');
    expect(ran).toContain('configure-i18n');
    expect(ran).toContain('configure-data-layer');
    expect(ran).toContain('write-project-config');
    expect(ran).toContain('finalize');
  });

  test('exit 1 when a step has no saved args', async () => {
    sandbox = setupSandbox();
    writeState(sandbox.root, {completed_steps: [], step_args: {}});

    const exit = await run([], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('missing_step_args');
  });

  test('propagates non-zero exit from a step runner', async () => {
    sandbox = setupSandbox();
    writeState(sandbox.root, {
      completed_steps: [],
      step_args: {'strip-branding': {title: 'X'}},
    });

    const exit = await run([], {
      cwd: sandbox.root,
      runners: {
        'strip-branding': () => 2,
      },
    });
    expect(exit).toBe(2);
  });

  test.each([
    ['99, out of range', '99', '--from-step must be'],
    ['8, because only seven steps exist', '8', '--from-step must be'],
    ['0', '0', ''],
  ])('--from-step %s exits 1', async (_name, value, message) => {
    sandbox = setupSandbox();
    const exit = await run(['--from-step', value], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(message);
  });

  test('--from-step 6 replays write-project-config from its saved args', async () => {
    sandbox = setupSandbox();
    writeState(sandbox.root, {
      completed_steps: [],
      step_args: {
        'write-project-config': {
          isolation_policy: 'prefer-branch',
          sandbox_recommended: true,
        },
      },
    });

    const calls: {argv: readonly string[]; step: string}[] = [];

    const stub = (step: string) => (argv: readonly string[]) => {
      calls.push({argv, step});

      return 0;
    };

    const exit = await run(['--from-step', '6'], {
      cwd: sandbox.root,
      runners: {
        finalize: stub('finalize'),
        'write-project-config': stub('write-project-config'),
      },
    });
    expect(exit).toBe(0);
    expect(calls.map((call) => call.step)).toEqual([
      'write-project-config',
      'finalize',
    ]);
    expect(calls[0]?.argv).toEqual([
      '--sandbox-recommended',
      'true',
      '--isolation-policy',
      'prefer-branch',
    ]);
  });

  test('replays a saved configure-data-layer step through its runner', async () => {
    sandbox = setupSandbox();
    writeState(sandbox.root, {
      completed_steps: [],
      step_args: {
        'configure-data-layer': {casing: 'camel', layer: null, query: true},
        rename: {kebab: 'x', title: 'X'},
        'wire-statusline': {},
        'write-project-config': {sandbox_recommended: false},
      },
    });

    const calls: {argv: readonly string[]; step: string}[] = [];

    const stub = (step: string) => (argv: readonly string[]) => {
      calls.push({argv, step});

      return 0;
    };

    const exit = await run(['--from-step', '3'], {
      cwd: sandbox.root,
      runners: {
        'configure-data-layer': stub('configure-data-layer'),
        finalize: stub('finalize'),
        rename: stub('rename'),
        'wire-statusline': stub('wire-statusline'),
        'write-project-config': stub('write-project-config'),
      },
    });

    expect(exit).toBe(0);
    expect(calls[0]?.step).toBe('configure-data-layer');
    expect(calls[0]?.argv).toEqual(['--casing', 'camel', '--query', 'true']);
  });
});
