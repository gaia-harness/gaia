import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../../exit.js';
import {writeBuiltinDescriptor} from '../../util/package-fixture.js';
import {run} from '../bootstrap-env.js';

let root: string;
let errors: string[];
let outputs: string[];

beforeEach(() => {
  root = mkdtempSync(path.join(tmpdir(), 'gaia-setup-bootstrap-env-'));
  writeBuiltinDescriptor(root);
  errors = [];
  outputs = [];
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
    errors.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  });
});

afterEach(() => {
  vi.restoreAllMocks();
  rmSync(root, {force: true, recursive: true});
});

const frontendFile = (name: string): string =>
  path.join(root, 'frontend', name);

describe('gaia setup bootstrap-env', () => {
  test('copies frontend/.env.example to frontend/.env when .env is absent', () => {
    writeFileSync(frontendFile('.env.example'), 'FOO=bar\n', 'utf8');

    expect(run([], {cwd: root})).toBe(EXIT_CODES.OK);
    expect(readFileSync(frontendFile('.env'), 'utf8')).toBe('FOO=bar\n');
  });

  test('leaves an existing .env untouched', () => {
    writeFileSync(frontendFile('.env'), 'EXISTING=1\n', 'utf8');
    writeFileSync(frontendFile('.env.example'), 'FOO=bar\n', 'utf8');

    expect(run([], {cwd: root})).toBe(EXIT_CODES.OK);
    expect(readFileSync(frontendFile('.env'), 'utf8')).toBe('EXISTING=1\n');
  });

  test('is a no-op when .env.example is absent', () => {
    expect(run([], {cwd: root})).toBe(EXIT_CODES.OK);
    expect(existsSync(frontendFile('.env'))).toBe(false);
  });

  test('writes no init resume cursor', () => {
    writeFileSync(frontendFile('.env.example'), 'FOO=bar\n', 'utf8');

    run([], {cwd: root});

    expect(existsSync(path.join(root, '.gaia', 'init-state.json'))).toBe(false);
  });

  test('prints its usage on --help', () => {
    expect(run(['--help'], {cwd: root})).toBe(EXIT_CODES.OK);
    expect(outputs.join('')).toContain('Usage: gaia setup bootstrap-env');
  });

  test('rejects unknown flags', () => {
    expect(run(['--bogus'], {cwd: root})).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(errors.join('')).toContain('unknown flag');
  });
});
