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

  test('classifies undecided entries by standalone and required', () => {
    writeFeatureList(listPath, [
      {id: 'feat-x', scope: 'project', standalone: true},
      {id: 'feat-y', required: true, scope: 'machine', standalone: true},
      {id: 'feat-w', scope: 'project', standalone: false},
      {id: 'feat-z', scope: 'project', standalone: true},
      {id: 'feat-r', scope: 'project', standalone: true},
    ]);
    sandbox.writeProjectConfig({
      setup_decisions: {'feat-r': 'applied', 'feat-z': 'declined'},
      version: 1,
    });

    expect(drift('--json')).toBe(EXIT_CODES.OK);
    expect(actions()).toEqual({
      'feat-w': 'setup',
      'feat-x': 'ask',
      'feat-y': 'apply',
    });
    expect(report().decided).toEqual({
      'feat-r': 'applied',
      'feat-z': 'declined',
    });
    expect(report().recorded).toEqual({machine: 0, project: 2});
    expect(report().features).toBe(listPath);
  });

  test('with no records at all every entry is setup and decided is empty', () => {
    writeFeatureList(listPath, [
      {id: 'feat-x', scope: 'project', standalone: true},
      {id: 'feat-y', required: true, scope: 'machine', standalone: true},
    ]);

    drift('--json');

    expect(actions()).toEqual({'feat-x': 'setup', 'feat-y': 'setup'});
    expect(report().decided).toEqual({});
    expect(report().recorded).toEqual({machine: 0, project: 0});
  });

  test('machine records count and decide machine ids', () => {
    writeFeatureList(listPath, [
      {id: 'mach-a', scope: 'machine', standalone: true},
      {id: 'proj-a', scope: 'project', standalone: true},
    ]);
    writeState({'mach-a': 'applied'});

    drift('--json');

    expect(report().decided).toEqual({'mach-a': 'applied'});
    expect(report().recorded).toEqual({machine: 1, project: 0});
    expect(actions()).toEqual({'proj-a': 'ask'});
  });

  test('ignores an unlisted id, an invalid value and a wrong-scope record', () => {
    writeFeatureList(listPath, [
      {id: 'mach-a', scope: 'machine', standalone: true},
      {id: 'proj-a', scope: 'project', standalone: true},
    ]);
    sandbox.writeProjectConfig({
      setup_decisions: {
        'mach-a': 'applied',
        'proj-a': 'maybe',
        unlisted: 'applied',
      },
      version: 1,
    });

    expect(drift('--json')).toBe(EXIT_CODES.OK);
    expect(report().decided).toEqual({});
    expect(report().recorded).toEqual({machine: 0, project: 0});
    expect(
      Object.keys(actions()).toSorted((a, b) => a.localeCompare(b))
    ).toEqual(['mach-a', 'proj-a']);
  });

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

  test('an unreadable path, an invalid list and malformed record files exit non-zero naming the file', () => {
    expect(drift('--json')).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(err.join('')).toContain(listPath);

    writeFileSync(listPath, '{"version": 2}', 'utf8');
    err.length = 0;
    expect(drift('--json')).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(err.join('')).toContain(listPath);

    writeFeatureList(listPath, [{id: 'proj-a', scope: 'project'}]);
    writeFileSync(projectConfigPath(sandbox.root), '{nope', 'utf8');
    err.length = 0;
    expect(drift('--json')).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(err.join('')).toContain('project.json');

    writeFileSync(projectConfigPath(sandbox.root), '{"version":1}', 'utf8');
    writeState({});
    writeFileSync(resolveStateFilePath(sandbox.root), '{nope', 'utf8');
    err.length = 0;
    expect(drift('--json')).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(err.join('')).toContain('state_malformed');
  });

  test('an unknown flag is refused', () => {
    expect(run(['--bogus'], {cwd: sandbox.root})).toBe(
      EXIT_CODES.UNKNOWN_SUBCOMMAND
    );
    expect(run(['--features'], {cwd: sandbox.root})).toBe(
      EXIT_CODES.UNKNOWN_SUBCOMMAND
    );
  });
});
