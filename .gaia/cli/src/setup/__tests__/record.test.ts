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
  readProjectJson,
  readStateJson,
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

  test('a project id lands in setup_decisions and every other key survives', () => {
    sandbox.writeProjectConfig({
      isolation_policy: 'prefer-branch',
      sandbox_recommended: true,
      setup_decisions: {other: 'declined'},
      version: 1,
    });

    expect(run(['proj-a', 'applied'], options())).toBe(EXIT_CODES.OK);

    const written = readProjectJson(sandbox.root);
    expect(written.setup_decisions).toEqual({
      other: 'declined',
      'proj-a': 'applied',
    });
    expect(written.sandbox_recommended).toBe(true);
    expect(written.isolation_policy).toBe('prefer-branch');
    expect(JSON.parse(stdio.out.join(''))).toEqual({
      decision: 'applied',
      id: 'proj-a',
      previous: null,
      scope: 'project',
    });
  });

  test('a machine id lands in setup-state decisions and the file is created', () => {
    expect(run(['mach-a', 'declined'], options())).toBe(EXIT_CODES.OK);

    expect(readStateJson(sandbox.root)).toEqual({
      completed_at: null,
      completed_steps: [],
      decisions: {'mach-a': 'declined'},
      started_at: '2026-01-02T03:04:05.000Z',
      version: 1,
    });
    expect(existsSync(projectConfigPath(sandbox.root))).toBe(false);
  });

  test('a machine id merges into an existing state without touching steps', () => {
    writeStateJson(sandbox.root, {
      completed_at: null,
      completed_steps: ['install-tools'],
      decisions: {kept: 'applied'},
      started_at: '2025-01-01T00:00:00.000Z',
      version: 1,
    });

    expect(run(['mach-a', 'not-applicable'], options())).toBe(EXIT_CODES.OK);

    const state = readStateJson(sandbox.root);
    expect(state.decisions).toEqual({
      kept: 'applied',
      'mach-a': 'not-applicable',
    });
    expect(state.completed_steps).toEqual(['install-tools']);
    expect(state.started_at).toBe('2025-01-01T00:00:00.000Z');
  });

  test('records merge per id and report the previous value', () => {
    run(['proj-a', 'applied'], options());
    run(['proj-b', 'declined'], options());
    stdio.out.length = 0;
    run(['proj-a', 'declined'], options());

    expect(readProjectJson(sandbox.root).setup_decisions).toEqual({
      'proj-a': 'declined',
      'proj-b': 'declined',
    });
    expect(JSON.parse(stdio.out.join('')).previous).toBe('applied');
  });

  test('an unlisted id and a bad value are refused with both files untouched', () => {
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
    const projectBefore = fileText(projectConfigPath(sandbox.root));
    const stateBefore = fileText(resolveStateFilePath(sandbox.root));

    expect(run(['not-listed', 'applied'], options())).not.toBe(EXIT_CODES.OK);
    expect(stdio.err.join('')).toContain('unknown_setup_feature');
    expect(run(['proj-a', 'maybe'], options())).not.toBe(EXIT_CODES.OK);
    expect(stdio.err.join('')).toContain('invalid_decision');
    expect(run(['mach-a', 'maybe'], options())).not.toBe(EXIT_CODES.OK);

    expect(fileText(projectConfigPath(sandbox.root))).toBe(projectBefore);
    expect(fileText(resolveStateFilePath(sandbox.root))).toBe(stateBefore);
  });

  test('a wrong argument count is refused', () => {
    expect(run(['proj-a'], options())).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(run(['proj-a', 'applied', 'extra'], options())).toBe(
      EXIT_CODES.UNKNOWN_SUBCOMMAND
    );
    expect(stdio.err.join('')).toContain('invalid_arguments');
  });

  test('an unreadable list is refused and nothing is written', () => {
    writeFileSync(listPathIn(sandbox.root), '{nope', 'utf8');

    expect(run(['proj-a', 'applied'], options())).toBe(
      EXIT_CODES.CONFIG_INVALID
    );
    expect(stdio.err.join('')).toContain('setup_features_invalid');
    expect(existsSync(projectConfigPath(sandbox.root))).toBe(false);
  });

  test('a malformed project.json is refused and left as it was', () => {
    writeFileSync(projectConfigPath(sandbox.root), '{not json', 'utf8');

    expect(run(['proj-a', 'applied'], options())).toBe(
      EXIT_CODES.CONFIG_INVALID
    );
    expect(stdio.err.join('')).toContain('config_malformed');
    expect(fileText(projectConfigPath(sandbox.root))).toBe('{not json');
  });

  test('a malformed setup-state.json is refused and left as it was', () => {
    const target = resolveStateFilePath(sandbox.root);
    writeStateJson(sandbox.root, {});
    writeFileSync(target, '{not json', 'utf8');

    expect(run(['mach-a', 'applied'], options())).toBe(
      EXIT_CODES.CONFIG_INVALID
    );
    expect(stdio.err.join('')).toContain('state_malformed');
    expect(fileText(target)).toBe('{not json');
  });

  test('--help exits 0 and no arguments exits 1, both printing usage', () => {
    expect(run(['--help'], options())).toBe(EXIT_CODES.OK);
    expect(run([], options())).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(stdio.out.join('')).toContain('Usage: gaia setup record');
  });
});
