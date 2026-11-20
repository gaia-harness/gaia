import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {existsSync, readFileSync, writeFileSync} from 'node:fs';
import {EXIT_CODES} from '../../exit.js';
import {projectConfigPath} from '../../schemas/project-config.js';
import {run} from '../record.js';
import {resolveStateFilePath} from '../util/state-file.js';
import {setupSandbox} from './sandbox.js';
import type {Sandbox} from './sandbox.js';
import {
  listPathIn,
  writeFeatureList,
  writeStateJson,
} from './setup-decisions-fixture.js';

const captureStdio = (): {
  err: string[];
  out: string[];
  restore: () => void;
} => {
  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      err.push(String(chunk));

      return true;
    });

  return {
    err,
    out,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const fileText = (filePath: string): null | string =>
  existsSync(filePath) ? readFileSync(filePath, 'utf8') : null;

describe('setup record', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  const options = () => ({
    cwd: sandbox.root,
    now: () => new Date('2026-01-02T03:04:05.000Z'),
  });

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-record-');
    stdio = captureStdio();
    writeFeatureList(listPathIn(sandbox.root), [
      {id: 'proj-a', scope: 'project'},
      {id: 'proj-b', scope: 'project'},
      {id: 'mach-a', scope: 'machine'},
    ]);
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  const fileSnapshot = (): {project: null | string; state: null | string} => ({
    project: fileText(projectConfigPath(sandbox.root)),
    state: fileText(resolveStateFilePath(sandbox.root)),
  });

  const recordedSnapshot = (): unknown => {
    const project = fileText(projectConfigPath(sandbox.root));
    const state = fileText(resolveStateFilePath(sandbox.root));
    const lastOutput = stdio.out.at(-1);

    return {
      output: lastOutput === undefined ? null : JSON.parse(lastOutput),
      project: project === null ? null : JSON.parse(project),
      state: state === null ? null : JSON.parse(state),
    };
  };

  test.each([
    {
      calls: [['proj-a', 'applied']],
      expected: {
        output: {
          decision: 'applied',
          id: 'proj-a',
          previous: null,
          scope: 'project',
        },
        project: {
          isolation_policy: 'prefer-branch',
          sandbox_recommended: true,
          setup_decisions: {other: 'declined', 'proj-a': 'applied'},
          version: 1,
        },
        state: null,
      },
      name: 'a project id lands in setup_decisions and every other key survives',
      setup: () => {
        sandbox.writeProjectConfig({
          isolation_policy: 'prefer-branch',
          sandbox_recommended: true,
          setup_decisions: {other: 'declined'},
          version: 1,
        });
      },
    },
    {
      calls: [['mach-a', 'declined']],
      expected: {
        output: {
          decision: 'declined',
          id: 'mach-a',
          previous: null,
          scope: 'machine',
        },
        project: null,
        state: {
          completed_at: null,
          completed_steps: [],
          decisions: {'mach-a': 'declined'},
          started_at: '2026-01-02T03:04:05.000Z',
          version: 1,
        },
      },
      name: 'a machine id lands in setup-state decisions and the file is created',
      setup: () => {},
    },
    {
      calls: [['mach-a', 'not-applicable']],
      expected: {
        output: {
          decision: 'not-applicable',
          id: 'mach-a',
          previous: null,
          scope: 'machine',
        },
        project: null,
        state: {
          completed_at: null,
          completed_steps: ['install-tools'],
          decisions: {kept: 'applied', 'mach-a': 'not-applicable'},
          started_at: '2025-01-01T00:00:00.000Z',
          version: 1,
        },
      },
      name: 'a machine id merges into an existing state without touching steps',
      setup: () => {
        writeStateJson(sandbox.root, {
          completed_at: null,
          completed_steps: ['install-tools'],
          decisions: {kept: 'applied'},
          started_at: '2025-01-01T00:00:00.000Z',
          version: 1,
        });
      },
    },
    {
      calls: [
        ['proj-a', 'applied'],
        ['proj-b', 'declined'],
        ['proj-a', 'declined'],
      ],
      expected: {
        output: {
          decision: 'declined',
          id: 'proj-a',
          previous: 'applied',
          scope: 'project',
        },
        project: {
          setup_decisions: {'proj-a': 'declined', 'proj-b': 'declined'},
          version: 1,
        },
        state: null,
      },
      name: 'records merge per id and report the previous value',
      setup: () => {},
    },
  ])('$name', ({calls, expected, setup}) => {
    setup();

    for (const argv of calls) {
      stdio.out.length = 0;
      expect(run(argv, options())).toBe(EXIT_CODES.OK);
    }

    expect(recordedSnapshot()).toEqual(expected);
  });

  test.each([
    {
      calls: [
        {argv: ['not-listed', 'applied'], exit: EXIT_CODES.UNKNOWN_SUBCOMMAND},
        {argv: ['proj-a', 'maybe'], exit: EXIT_CODES.UNKNOWN_SUBCOMMAND},
        {argv: ['mach-a', 'maybe'], exit: EXIT_CODES.UNKNOWN_SUBCOMMAND},
      ],
      name: 'an unlisted id and a bad value are refused with both files untouched',
      setup: () => {
        sandbox.writeProjectConfig({
          setup_decisions: {other: 'declined'},
          version: 1,
        });
        writeStateJson(sandbox.root, {
          completed_at: null,
          completed_steps: [],
          decisions: {},
          started_at: 'x',
          version: 1,
        });
      },
      stderr: ['unknown_setup_feature', 'invalid_decision'],
    },
    {
      calls: [
        {argv: ['proj-a'], exit: EXIT_CODES.UNKNOWN_SUBCOMMAND},
        {
          argv: ['proj-a', 'applied', 'extra'],
          exit: EXIT_CODES.UNKNOWN_SUBCOMMAND,
        },
      ],
      name: 'a wrong argument count is refused',
      setup: () => {},
      stderr: ['invalid_arguments'],
    },
    {
      calls: [{argv: ['proj-a', 'applied'], exit: EXIT_CODES.CONFIG_INVALID}],
      name: 'an unreadable list is refused and nothing is written',
      setup: () => {
        writeFileSync(listPathIn(sandbox.root), '{nope', 'utf8');
      },
      stderr: ['setup_features_invalid'],
    },
    {
      calls: [{argv: ['proj-a', 'applied'], exit: EXIT_CODES.CONFIG_INVALID}],
      name: 'a malformed project.json is refused and left as it was',
      setup: () => {
        writeFileSync(projectConfigPath(sandbox.root), '{not json', 'utf8');
      },
      stderr: ['config_malformed'],
    },
    {
      calls: [{argv: ['mach-a', 'applied'], exit: EXIT_CODES.CONFIG_INVALID}],
      name: 'a malformed setup-state.json is refused and left as it was',
      setup: () => {
        writeStateJson(sandbox.root, {});
        writeFileSync(resolveStateFilePath(sandbox.root), '{not json', 'utf8');
      },
      stderr: ['state_malformed'],
    },
  ])('$name', ({calls, setup, stderr}) => {
    setup();
    const before = fileSnapshot();

    for (const {argv, exit} of calls) {
      expect(run(argv, options())).toBe(exit);
    }

    for (const fragment of stderr) {
      expect(stdio.err.join('')).toContain(fragment);
    }
    expect(fileSnapshot()).toEqual(before);
  });

  test('--help exits 0 and no arguments exits 1, both printing usage', () => {
    expect(run(['--help'], options())).toBe(EXIT_CODES.OK);
    expect(run([], options())).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(stdio.out.join('')).toContain('Usage: gaia setup record');
  });
});
