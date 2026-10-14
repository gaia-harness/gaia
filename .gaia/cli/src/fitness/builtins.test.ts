import {afterEach, describe, expect, test} from 'vitest';
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {
  findOnPath,
  MAX_CAPTURE_BYTES,
  relativizeRoot,
  TIMEOUT_ENV,
  TRUNCATION_MARKER,
} from './builtins.js';
import {compareBytes} from './markdown.js';
import {createScratchProject, runFitness} from './test-support.js';
import type {FixtureProject} from './types.js';

type Entry = {
  exit_code?: number;
  name: string;
  output?: string;
  reason?: string;
  results?: {
    exit_code?: number;
    json?: unknown;
    reason?: string;
    status: string;
    target: string;
  }[];
  status: string;
  targets?: string[];
};

type Report = {builtins: Entry[]};

const SYSTEM_PATH = '/usr/bin:/bin';
const VALIDATE_ARGUMENT_COUNT = 4;

const cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

const scratchDirectory = (): string => {
  const directory = mkdtempSync(path.join(tmpdir(), 'gaia-builtins-'));

  cleanups.push(() => {
    rmSync(directory, {force: true, recursive: true});
  });

  return directory;
};

const project = (extra: Record<string, string> = {}): FixtureProject => ({
  files: {
    '.claude/agents/example.md': '---\nname: example\n---\nBody\n',
    '.claude/commands/example.md': '---\ndescription: example\n---\nBody\n',
    '.claude/skills/example/SKILL.md': '---\nname: example\n---\nBody\n',
    'CLAUDE.md': '# Project\n',
    'frontend/.claude/skills/other/SKILL.md': '---\nname: other\n---\nBody\n',
    ...extra,
  },
  git: true,
});

const scratch = (fixture: FixtureProject) => {
  const created = createScratchProject(fixture);

  cleanups.push(created.cleanup);

  return created;
};

type StubBehavior = {doctor?: string; validate?: string};

/** Writes a stub `claude` that logs its argv and env, then runs the given shell snippets. */
const writeStub = (behavior: StubBehavior) => {
  const directory = scratchDirectory();
  const argvLog = path.join(directory, 'argv.log');
  const envLog = path.join(directory, 'env.log');
  const script = [
    '#!/bin/sh',
    String.raw`printf '%s\n' "$*" >> '${argvLog}'`,
    `env > '${envLog}'`,
    'case "$1" in',
    `  doctor) ${behavior.doctor ?? 'echo "doctor ok"'} ;;`,
    `  plugin) ${
      behavior.validate ??
      String.raw`printf '{"success": true, "contents": [{"path": "x"}]}\n'`
    } ;;`,
    'esac',
    '',
  ].join('\n');
  const binary = path.join(directory, 'claude');

  writeFileSync(binary, script);
  chmodSync(binary, 0o755);

  return {
    argvLines: (): string[] => {
      try {
        return readFileSync(argvLog, 'utf8').split('\n').filter(Boolean);
      } catch {
        return [];
      }
    },
    directory,
    env: (): string => readFileSync(envLog, 'utf8'),
  };
};

const runBuiltinsCommand = async (
  root: string,
  environment: Record<string, string | undefined>
) => {
  const result = await runFitness(['builtins', '--json', '--root', root], {
    env: environment,
  });

  return {...result, report: result.json as Report};
};

const entryNamed = (report: Report, name: string): Entry => {
  const found = report.builtins.find((entry) => entry.name === name);

  if (found === undefined) throw new Error(`no builtin entry named ${name}`);

  return found;
};

describe('gaia fitness builtins with claude present', () => {
  test('records doctor raw and validates each directory with --json', async () => {
    const {root} = scratch(project());
    const stub = writeStub({doctor: 'echo "doctor says hello"; exit 0'});
    const {exitCode, report} = await runBuiltinsCommand(root, {
      GAIA_TEST_SECRET: 'planted-value',
      PATH: `${stub.directory}:${SYSTEM_PATH}`,
    });

    expect(exitCode).toBe(EXIT_CODES.OK);

    const doctor = entryNamed(report, 'claude doctor');

    expect(doctor.status).toBe('ran');
    expect(doctor.exit_code).toBe(0);
    expect(doctor.output).toContain('doctor says hello');

    const validate = entryNamed(report, 'claude plugin validate');

    expect(validate.status).toBe('ran');
    expect(validate.targets).toEqual([
      '.claude/agents',
      '.claude/commands',
      '.claude/skills',
      'frontend/.claude/skills',
    ]);
    expect(validate.results?.map((result) => result.status)).toEqual([
      'ran',
      'ran',
      'ran',
      'ran',
    ]);
    expect(validate.results?.[0]?.json).toEqual({
      contents: [{path: 'x'}],
      success: true,
    });

    const validateCalls = stub
      .argvLines()
      .filter((line) => line.startsWith('plugin'));

    expect(validateCalls.toSorted(compareBytes)).toEqual(
      (validate.targets ?? []).map(
        (target) => `plugin validate ${target} --json`
      )
    );
    expect(validateCalls).toHaveLength(VALIDATE_ARGUMENT_COUNT);
    expect(stub.argvLines().join('\n')).not.toMatch(
      /dangerously|bypass|skip-permissions|trust/i
    );
  });

  test('the child env holds none of the parent variables outside the allowlist', async () => {
    const {root} = scratch(project());
    const stub = writeStub({});

    await runBuiltinsCommand(root, {
      GAIA_TEST_SECRET: 'planted-value',
      PATH: `${stub.directory}:${SYSTEM_PATH}`,
    });

    const seen = stub.env();

    expect(seen).not.toContain('GAIA_TEST_SECRET');
    expect(seen).not.toContain('planted-value');
    expect(seen).toContain('PATH=');
  });

  test('a validate that walks no file is skipped, never ran', async () => {
    const {root} = scratch(project());
    const stub = writeStub({
      validate: String.raw`printf '{"success": true, "manifest": null, "contents": []}\n'`,
    });
    const {report} = await runBuiltinsCommand(root, {
      PATH: `${stub.directory}:${SYSTEM_PATH}`,
    });
    const validate = entryNamed(report, 'claude plugin validate');

    expect(validate.status).toBe('skipped');
    expect(validate.reason).toBe('validated no file');
    expect(validate.results?.length).toBeGreaterThan(0);

    for (const result of validate.results ?? []) {
      expect(result.status).toBe('skipped');
      expect(result.reason).toBe('validated no file');
      expect(result.exit_code).toBe(0);
    }
  });

  test('a validate without a contents key counts as walking no file', async () => {
    const {root} = scratch(project());
    const stub = writeStub({
      validate: String.raw`printf '{"success": true}\n'`,
    });
    const {report} = await runBuiltinsCommand(root, {
      PATH: `${stub.directory}:${SYSTEM_PATH}`,
    });

    expect(entryNamed(report, 'claude plugin validate').status).toBe('skipped');
  });

  test('absolute root paths in the validate JSON are rewritten repo-relative', async () => {
    const {root} = scratch(project());
    const realRoot = realpathSync(root);
    const stub = writeStub({
      validate: [
        String.raw`printf '{"success": true, "target": "${root}/%s", "manifest": {"file": "${realRoot}/.claude-plugin/plugin.json"}, "contents": [{"path": "${root}/%s/example.md"}, {"path": "${root}"}]}\n' "$3" "$3"`,
      ].join('\n'),
    });
    const {exitCode, report, stdout} = await runBuiltinsCommand(root, {
      PATH: `${stub.directory}:${SYSTEM_PATH}`,
    });

    expect(exitCode).toBe(EXIT_CODES.OK);
    expect(stdout).not.toContain(root);
    expect(stdout).not.toContain(realRoot);

    const first = entryNamed(report, 'claude plugin validate').results?.[0];

    expect(first?.json).toEqual({
      contents: [{path: '.claude/agents/example.md'}, {path: '.'}],
      manifest: {file: '.claude-plugin/plugin.json'},
      success: true,
      target: '.claude/agents',
    });
  });

  test('a validate that reports non-JSON output keeps the exit code and a null json', async () => {
    const {root} = scratch(project());
    const stub = writeStub({validate: 'echo "something odd"; exit 4'});
    const {report} = await runBuiltinsCommand(root, {
      PATH: `${stub.directory}:${SYSTEM_PATH}`,
    });
    const validate = entryNamed(report, 'claude plugin validate');

    expect(validate.status).toBe('ran');
    expect(validate.results?.[0]).toMatchObject({
      exit_code: 4,
      json: null,
      status: 'ran',
    });
  });

  test('a claude that does not know --json skips the whole validate entry', async () => {
    const {root} = scratch(project());
    const stub = writeStub({
      validate: `echo "error: unknown option '--json'" >&2; exit 1`,
    });
    const {report} = await runBuiltinsCommand(root, {
      PATH: `${stub.directory}:${SYSTEM_PATH}`,
    });
    const validate = entryNamed(report, 'claude plugin validate');

    expect(validate.status).toBe('skipped');
    expect(validate.reason).toBe(
      'this claude version does not support plugin validate --json'
    );
    expect(entryNamed(report, 'claude doctor').status).toBe('ran');
  });

  test('no skill, agent or command directory skips validate with its reason', async () => {
    const {root} = scratch({files: {'CLAUDE.md': '# Project\n'}, git: true});
    const stub = writeStub({});
    const {report} = await runBuiltinsCommand(root, {
      PATH: `${stub.directory}:${SYSTEM_PATH}`,
    });
    const validate = entryNamed(report, 'claude plugin validate');

    expect(validate.status).toBe('skipped');
    expect(validate.reason).toBe('no skill, agent or command directory');
    expect(stub.argvLines().some((line) => line.startsWith('plugin'))).toBe(
      false
    );
  });

  test('a doctor that runs past the timeout is killed and recorded skipped', async () => {
    const {root} = scratch(project());
    const stub = writeStub({doctor: 'sleep 5', validate: 'sleep 5'});
    const started = Date.now();
    const {report} = await runBuiltinsCommand(root, {
      PATH: `${stub.directory}:${SYSTEM_PATH}`,
      [TIMEOUT_ENV]: '200',
    });
    const doctor = entryNamed(report, 'claude doctor');
    const validate = entryNamed(report, 'claude plugin validate');

    expect(doctor.status).toBe('skipped');
    expect(doctor.reason).toBe('timed out after 200 ms');
    expect(validate.status).toBe('skipped');
    expect(validate.reason).toBe('timed out after 200 ms');
    expect(Date.now() - started).toBeLessThan(5000);
  });

  test('a credential-shaped value in the output never reaches stdout', async () => {
    const {root} = scratch(project());
    const secret = `sk-ant-${'a1B2c3D4'.repeat(4)}`;
    const stub = writeStub({doctor: `echo "token is ${secret}"`});
    const {stdout} = await runBuiltinsCommand(root, {
      PATH: `${stub.directory}:${SYSTEM_PATH}`,
    });

    for (let start = 0; start + 8 <= secret.length; start += 1) {
      expect(stdout).not.toContain(secret.slice(start, start + 8));
    }

    expect(stdout).toContain('[redacted]');
  });

  test('output past the byte cap is truncated with the marker', async () => {
    const {root} = scratch(project());
    const stub = writeStub({
      doctor: String.raw`head -c ${MAX_CAPTURE_BYTES * 2} /dev/zero | tr '\0' 'a'`,
    });
    const {report} = await runBuiltinsCommand(root, {
      PATH: `${stub.directory}:${SYSTEM_PATH}`,
    });
    const doctor = entryNamed(report, 'claude doctor');

    expect(doctor.output).toContain(TRUNCATION_MARKER);
    expect(doctor.output?.length).toBeLessThanOrEqual(
      MAX_CAPTURE_BYTES + TRUNCATION_MARKER.length
    );
  });
});

describe('gaia fitness builtins without claude', () => {
  test('both entries are skipped and nothing reports ran', async () => {
    const {root} = scratch(project());
    const emptyDirectory = scratchDirectory();
    const {exitCode, report} = await runBuiltinsCommand(root, {
      PATH: `${emptyDirectory}:${SYSTEM_PATH}`,
    });

    expect(
      findOnPath('claude', `${emptyDirectory}:${SYSTEM_PATH}`)
    ).toBeUndefined();
    expect(exitCode).toBe(EXIT_CODES.OK);
    expect(report.builtins.map((entry) => entry.name)).toEqual([
      'claude doctor',
      'claude plugin validate',
    ]);

    for (const entry of report.builtins) {
      expect(entry.status).toBe('skipped');
      expect(entry.reason).toBe('claude is not on PATH');
    }
  });
});

describe('gaia fitness builtins arguments', () => {
  test('an unknown argument exits 2', async () => {
    const result = await runFitness(['builtins', '--bogus']);

    expect(result.exitCode).toBe(EXIT_CODES.INVALID_ARGUMENTS);
  });

  test('--root without a value exits 2', async () => {
    const result = await runFitness(['builtins', '--root']);

    expect(result.exitCode).toBe(EXIT_CODES.INVALID_ARGUMENTS);
  });

  test('a root that is not a directory exits 3', async () => {
    const {root} = scratch(project());
    const result = await runFitness([
      'builtins',
      '--root',
      path.join(root, 'CLAUDE.md'),
    ]);

    expect(result.exitCode).toBe(EXIT_CODES.COULD_NOT_RUN);
    expect(result.stderr).toContain('could_not_run');
  });
});

describe('relativizeRoot', () => {
  test('rewrites only strings that start with the root at a path boundary', () => {
    const rewritten = relativizeRoot(
      {
        a: '/work/project/file.md',
        b: '/work/project',
        c: '/work/project-other/file.md',
        d: ['/work/project/x', 'keep /work/project/y'],
      },
      ['/work/project']
    );

    expect(rewritten).toEqual({
      a: 'file.md',
      b: '.',
      c: '/work/project-other/file.md',
      d: ['x', 'keep /work/project/y'],
    });
  });
});

describe('findOnPath', () => {
  test('skips a non-executable file and a directory named claude', () => {
    const directory = scratchDirectory();

    writeFileSync(path.join(directory, 'claude'), 'not executable');
    chmodSync(path.join(directory, 'claude'), 0o644);

    const other = scratchDirectory();

    mkdirSync(path.join(other, 'claude'));

    expect(findOnPath('claude', `${directory}:${other}`)).toBeUndefined();
  });
});
