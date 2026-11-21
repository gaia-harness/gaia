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

  test.each([
    {
      act: () => runMarkStep(['install-tools'], cwd()),
      decision: 'declined',
      name: 'mark-step keeps the decision',
      state: {},
    },
    {
      act: () => {
        for (const step of [
          'install-tools',
          'install-plugins',
          'chmod-statusline',
          'bootstrap-env',
        ]) {
          runMarkStep([step], cwd());
        }

        return runFinalize([], cwd());
      },
      decision: 'declined',
      name: 'finalize keeps the decision',
      state: {completed_at: expect.any(String)},
    },
    {
      act: () => runFinalize(['--force'], cwd()),
      decision: 'declined',
      name: 'finalize --force with a pending step keeps the decision',
      state: {completed_steps: []},
    },
    {
      act: () => {
        const statePath = resolveStateFilePath(sandbox.root);
        writeFileSync(
          statePath,
          JSON.stringify({...readStateJson(sandbox.root), admin: true}),
          'utf8'
        );
        runMarkStep(['install-tools'], cwd());
        runRecord(['mach-a', 'applied'], cwd());

        return runFinalize(['--force'], cwd());
      },
      decision: 'applied',
      name: 'mark-step, record and finalize keep the cached admin answer',
      state: {admin: true},
    },
  ])('$name', ({act, decision, state}) => {
    expect(act()).toBe(EXIT_CODES.OK);

    const written = readStateJson(sandbox.root);
    expect(written).toMatchObject(state);
    expect(written.decisions).toEqual({'mach-a': decision});
    out.length = 0;
    runDrift(['--json'], {cwd: sandbox.root});
    expect(
      JSON.parse(out.join('')).undecided.map((entry: {id: string}) => entry.id)
    ).not.toContain('mach-a');
  });
});
