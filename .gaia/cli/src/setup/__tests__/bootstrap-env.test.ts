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
  path.join(root, 'apps', 'web', name);

const writeIfPresent = (
  filePath: string,
  content: string | undefined
): void => {
  if (content !== undefined) {
    writeFileSync(filePath, content, 'utf8');
  }
};

const readIfPresent = (filePath: string): null | string =>
  existsSync(filePath) ? readFileSync(filePath, 'utf8') : null;

describe('gaia setup bootstrap-env', () => {
  test.each([
    {
      exampleEnv: 'FOO=bar\n',
      existingEnv: undefined,
      expectedEnv: 'FOO=bar\n',
      name: 'copies apps/web/.env.example to apps/web/.env when .env is absent',
    },
    {
      exampleEnv: 'FOO=bar\n',
      existingEnv: 'EXISTING=1\n',
      expectedEnv: 'EXISTING=1\n',
      name: 'leaves an existing .env untouched',
    },
    {
      exampleEnv: undefined,
      existingEnv: undefined,
      expectedEnv: null,
      name: 'is a no-op when .env.example is absent',
    },
  ])('$name', ({exampleEnv, existingEnv, expectedEnv}) => {
    writeIfPresent(frontendFile('.env'), existingEnv);
    writeIfPresent(frontendFile('.env.example'), exampleEnv);

    expect(run([], {cwd: root})).toBe(EXIT_CODES.OK);
    expect(readIfPresent(frontendFile('.env'))).toBe(expectedEnv);
  });

  test('writes no init resume cursor', () => {
    writeFileSync(frontendFile('.env.example'), 'FOO=bar\n', 'utf8');

    run([], {cwd: root});

    expect(existsSync(path.join(root, '.gaia', 'init-state.json'))).toBe(false);
  });

  test.each([
    {
      args: ['--help'],
      exit: EXIT_CODES.OK,
      name: 'prints its usage on --help',
      stream: 'outputs',
      text: 'Usage: gaia setup bootstrap-env',
    },
    {
      args: ['--bogus'],
      exit: EXIT_CODES.UNKNOWN_SUBCOMMAND,
      name: 'rejects unknown flags',
      stream: 'errors',
      text: 'unknown flag',
    },
  ] as const)('$name', ({args, exit, stream, text}) => {
    expect(run([...args], {cwd: root})).toBe(exit);
    expect({errors, outputs}[stream].join('')).toContain(text);
  });
});
