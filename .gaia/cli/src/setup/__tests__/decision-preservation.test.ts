import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {writeFileSync} from 'node:fs';
import {EXIT_CODES} from '../../exit.js';
import {run as runDrift} from '../drift.js';
import {run as runFinalize} from '../finalize.js';
import {run as runMarkStep} from '../mark-step.js';
import {run as runRecord} from '../record.js';
import {resolveStateFilePath} from '../util/state-file.js';
import {setupSandbox} from './sandbox.js';
import type {Sandbox} from './sandbox.js';
import {
  listPathIn,
  readStateJson,
  writeFeatureList,
} from './setup-decisions-fixture.js';

describe('machine decisions across setup-state writes', () => {
  let sandbox: Sandbox;
  let out: string[];

  const cwd = (): {cwd: string; now: () => Date} => ({
    cwd: sandbox.root,
    now: () => new Date('2026-01-02T03:04:05.000Z'),
  });

  const expectDecisionKept = (): void => {
    expect(readStateJson(sandbox.root).decisions).toEqual({
      'mach-a': 'declined',
    });
    out.length = 0;
    runDrift(['--json'], {cwd: sandbox.root});
    expect(
      JSON.parse(out.join('')).undecided.map((entry: {id: string}) => entry.id)
    ).not.toContain('mach-a');
  };

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-decisions-kept-');
    out = [];
    vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
      out.push(String(chunk));

      return true;
    });
    vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    writeFeatureList(listPathIn(sandbox.root), [
      {id: 'mach-a', scope: 'machine'},
    ]);
    runRecord(['mach-a', 'declined'], cwd());
  });

  afterEach(() => {
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('mark-step keeps the decision', () => {
    expect(runMarkStep(['install-tools'], cwd())).toBe(EXIT_CODES.OK);
    expectDecisionKept();
  });

  test('finalize keeps the decision', () => {
    for (const step of [
      'install-tools',
      'install-plugins',
      'chmod-statusline',
      'bootstrap-env',
    ]) {
      runMarkStep([step], cwd());
    }

    expect(runFinalize([], cwd())).toBe(EXIT_CODES.OK);
    expect(readStateJson(sandbox.root).completed_at).not.toBeNull();
    expectDecisionKept();
  });

  test('finalize --force with a pending step keeps the decision', () => {
    expect(runFinalize(['--force'], cwd())).toBe(EXIT_CODES.OK);
    expect(readStateJson(sandbox.root).completed_steps).toEqual([]);
    expectDecisionKept();
  });

  test('mark-step, record and finalize keep the cached admin answer', () => {
    const statePath = resolveStateFilePath(sandbox.root);
    writeFileSync(
      statePath,
      JSON.stringify({...readStateJson(sandbox.root), admin: true}),
      'utf8'
    );
    runMarkStep(['install-tools'], cwd());
    runRecord(['mach-a', 'applied'], cwd());
    runFinalize(['--force'], cwd());
    expect(readStateJson(sandbox.root).admin).toBe(true);
  });
});
