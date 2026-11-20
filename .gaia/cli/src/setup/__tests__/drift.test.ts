import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../../exit.js';
import {projectConfigPath} from '../../schemas/project-config.js';
import {run} from '../drift.js';
import {resolveStateFilePath} from '../util/state-file.js';
import {setupSandbox} from './sandbox.js';
import type {Sandbox} from './sandbox.js';
import {writeFeatureList, writeStateJson} from './setup-decisions-fixture.js';

type Report = {
  decided: Record<string, string>;
  features: string;
  recorded: {machine: number; project: number};
  undecided: {action: string; id: string}[];
};

describe('setup drift', () => {
  let sandbox: Sandbox;
  let out: string[];
  let err: string[];
  let listPath: string;

  const drift = (...argv: string[]): number =>
    run(['--features', listPath, ...argv], {cwd: sandbox.root});
  const report = (): Report => JSON.parse(out.join('')) as Report;
  const actions = (): Record<string, string> =>
    Object.fromEntries(
      report().undecided.map((entry) => [entry.id, entry.action])
    );

  const writeState = (decisions: Record<string, unknown>): void => {
    writeStateJson(sandbox.root, {
      completed_at: null,
      completed_steps: [],
      decisions,
      started_at: 'x',
      version: 1,
    });
  };

  const writeProjectConfigIfPresent = (
    config: Record<string, unknown> | undefined
  ): void => {
    if (config !== undefined) {
      sandbox.writeProjectConfig(config);
    }
  };

  const writeStateIfPresent = (
    decisions: Record<string, unknown> | undefined
  ): void => {
    if (decisions !== undefined) {
      writeState(decisions);
    }
  };

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-drift-');
    listPath = path.join(sandbox.root, 'fixture-list.json');
    out = [];
    err = [];
    vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
      out.push(String(chunk));

      return true;
    });
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
      err.push(String(chunk));

      return true;
    });
  });

  afterEach(() => {
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test.each([
    {
      actions: {'feat-w': 'setup', 'feat-x': 'ask', 'feat-y': 'apply'},
      decided: {'feat-r': 'applied', 'feat-z': 'declined'},
      features: [
        {id: 'feat-x', scope: 'project', standalone: true},
        {id: 'feat-y', required: true, scope: 'machine', standalone: true},
        {id: 'feat-w', scope: 'project', standalone: false},
        {id: 'feat-z', scope: 'project', standalone: true},
        {id: 'feat-r', scope: 'project', standalone: true},
      ],
      name: 'classifies undecided entries by standalone and required',
      projectConfig: {
        setup_decisions: {'feat-r': 'applied', 'feat-z': 'declined'},
        version: 1,
      },
      recorded: {machine: 0, project: 2},
      state: undefined,
    },
    {
      actions: {'feat-x': 'setup', 'feat-y': 'setup'},
      decided: {},
      features: [
        {id: 'feat-x', scope: 'project', standalone: true},
        {id: 'feat-y', required: true, scope: 'machine', standalone: true},
      ],
      name: 'with no records at all every entry is setup and decided is empty',
      projectConfig: undefined,
      recorded: {machine: 0, project: 0},
      state: undefined,
    },
    {
      actions: {'proj-a': 'ask'},
      decided: {'mach-a': 'applied'},
      features: [
        {id: 'mach-a', scope: 'machine', standalone: true},
        {id: 'proj-a', scope: 'project', standalone: true},
      ],
      name: 'machine records count and decide machine ids',
      projectConfig: undefined,
      recorded: {machine: 1, project: 0},
      state: {'mach-a': 'applied'},
    },
    {
      actions: {'mach-a': 'setup', 'proj-a': 'setup'},
      decided: {},
      features: [
        {id: 'mach-a', scope: 'machine', standalone: true},
        {id: 'proj-a', scope: 'project', standalone: true},
      ],
      name: 'ignores an unlisted id, an invalid value and a wrong-scope record',
      projectConfig: {
        setup_decisions: {
          'mach-a': 'applied',
          'proj-a': 'maybe',
          unlisted: 'applied',
        },
        version: 1,
      },
      recorded: {machine: 0, project: 0},
      state: undefined,
    },
  ])(
    '$name',
    ({
      actions: expectedActions,
      decided,
      features,
      projectConfig,
      recorded,
      state,
    }) => {
      writeFeatureList(
        listPath,
        features as Parameters<typeof writeFeatureList>[1]
      );

      writeProjectConfigIfPresent(projectConfig);
      writeStateIfPresent(state);

      expect(drift('--json')).toBe(EXIT_CODES.OK);
      expect(actions()).toEqual(expectedActions);
      expect(report().decided).toEqual(decided);
      expect(report().recorded).toEqual(recorded);
      expect(report().features).toBe(listPath);
    }
  );

  test('prints one line per undecided entry, or the all-decided line', () => {
    writeFeatureList(listPath, [{id: 'proj-a', scope: 'project'}]);

    drift();
    expect(out.join('')).toBe('proj-a setup\n');

    out.length = 0;
    sandbox.writeProjectConfig({
      setup_decisions: {'proj-a': 'applied'},
      version: 1,
    });
    drift();
    expect(out.join('')).toBe('no undecided setup features\n');
  });

  test('uses the tracked list at the repo root by default', () => {
    writeFeatureList(path.join(sandbox.root, '.gaia', 'setup-features.json'), [
      {id: 'proj-a', scope: 'project'},
    ]);

    expect(run(['--json'], {cwd: sandbox.root})).toBe(EXIT_CODES.OK);
    expect(actions()).toEqual({'proj-a': 'setup'});
  });

  test.each([
    {
      args: (list: string) => ['--features', list, '--json'],
      exit: EXIT_CODES.CONFIG_INVALID,
      name: 'an unreadable path exits non-zero naming the file',
      prepare: () => {},
      stderr: (list: string) => list,
    },
    {
      args: (list: string) => ['--features', list, '--json'],
      exit: EXIT_CODES.CONFIG_INVALID,
      name: 'an invalid list exits non-zero naming the file',
      prepare: () => {
        writeFileSync(listPath, '{"version": 2}', 'utf8');
      },
      stderr: (list: string) => list,
    },
    {
      args: (list: string) => ['--features', list, '--json'],
      exit: EXIT_CODES.CONFIG_INVALID,
      name: 'a malformed project.json exits non-zero naming the file',
      prepare: () => {
        writeFeatureList(listPath, [{id: 'proj-a', scope: 'project'}]);
        writeFileSync(projectConfigPath(sandbox.root), '{nope', 'utf8');
      },
      stderr: () => 'project.json',
    },
    {
      args: (list: string) => ['--features', list, '--json'],
      exit: EXIT_CODES.CONFIG_INVALID,
      name: 'a malformed setup-state.json exits non-zero naming the file',
      prepare: () => {
        writeFeatureList(listPath, [{id: 'proj-a', scope: 'project'}]);
        writeFileSync(projectConfigPath(sandbox.root), '{"version":1}', 'utf8');
        writeState({});
        writeFileSync(resolveStateFilePath(sandbox.root), '{nope', 'utf8');
      },
      stderr: () => 'state_malformed',
    },
    {
      args: () => ['--bogus'],
      exit: EXIT_CODES.UNKNOWN_SUBCOMMAND,
      name: 'an unknown flag is refused',
      prepare: () => {},
      stderr: () => '',
    },
    {
      args: () => ['--features'],
      exit: EXIT_CODES.UNKNOWN_SUBCOMMAND,
      name: 'a --features flag with no value is refused',
      prepare: () => {},
      stderr: () => '',
    },
  ])('$name', ({args, exit, prepare, stderr}) => {
    prepare();

    expect(run(args(listPath), {cwd: sandbox.root})).toBe(exit);
    expect(err.join('')).toContain(stderr(listPath));
  });
});
