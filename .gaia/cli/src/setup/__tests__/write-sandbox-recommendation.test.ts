import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {existsSync, readFileSync, writeFileSync} from 'node:fs';
import {EXIT_CODES} from '../../exit.js';
import {projectConfigPath} from '../../schemas/project-config.js';
import {run} from '../write-sandbox-recommendation.js';
import {setupSandbox} from './sandbox.js';
import type {Sandbox} from './sandbox.js';
import {readProjectJson} from './setup-decisions-fixture.js';

describe('setup write-sandbox-recommendation', () => {
  let sandbox: Sandbox;
  let out: string[];
  let err: string[];

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-write-sandbox-rec-');
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
    ['true', true],
    ['false', false],
  ] as const)('writes %s and prints it', (token, expected) => {
    expect(run([token], {cwd: sandbox.root})).toBe(EXIT_CODES.OK);
    expect(readProjectJson(sandbox.root).sandbox_recommended).toBe(expected);
    expect(JSON.parse(out.join(''))).toEqual({sandbox_recommended: expected});
  });

  test('creates the file with version 1 when absent', () => {
    run(['true'], {cwd: sandbox.root});

    expect(readFileSync(projectConfigPath(sandbox.root), 'utf8')).toBe(
      '{\n  "version": 1,\n  "sandbox_recommended": true\n}\n'
    );
  });

  test('keeps unknown keys and setup_decisions', () => {
    sandbox.writeProjectConfig({
      future_key: 'x',
      setup_decisions: {a: 'applied'},
      version: 1,
    });

    run(['false'], {cwd: sandbox.root});

    const written = readProjectJson(sandbox.root);
    expect(written.future_key).toBe('x');
    expect(written.setup_decisions).toEqual({a: 'applied'});
    expect(written.sandbox_recommended).toBe(false);
  });

  test('refuses another token and writes nothing', () => {
    expect(run(['yes'], {cwd: sandbox.root})).not.toBe(EXIT_CODES.OK);
    expect(err.join('')).toContain('unrecognized value');
    expect(existsSync(projectConfigPath(sandbox.root))).toBe(false);
  });

  test('refuses a malformed file and leaves it unchanged', () => {
    writeFileSync(projectConfigPath(sandbox.root), '{not json', 'utf8');

    expect(run(['true'], {cwd: sandbox.root})).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(err.join('')).toContain('config_malformed');
    expect(readFileSync(projectConfigPath(sandbox.root), 'utf8')).toBe(
      '{not json'
    );
  });

  test('--help exits 0', () => {
    expect(run(['--help'], {cwd: sandbox.root})).toBe(EXIT_CODES.OK);
    expect(out.join('')).toContain('Usage:');
  });
});
