import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import type {SpawnSyncReturns} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {COMMIT_TYPES} from '../util/conventional-commit.js';
import {
  aggregateBump,
  applyBump,
  classifyCommit,
  collectCommits,
  defaultRunner,
  run,
} from './bump.js';
import type {CommandRunner} from './bump.js';

const expectedBump = (type: string): null | string => {
  if (type === 'feat') return 'minor';
  if (type === 'wiki') return null;

  return 'patch';
};

describe('classifyCommit', () => {
  type CommitCase = {
    commits: {body: string; subject: string}[];
    expected: null | string;
    name: string;
  };
  const bare = (...subjects: string[]): CommitCase['commits'] =>
    subjects.map((subject) => ({body: '', subject}));

  // `/gaia-debt` emits `debt(...)` and a rebundle emits `build(cli):`, so a
  // maintenance release window can consist entirely of these. They used to
  // classify as null, and a window of only such commits aggregated to no bump
  // at all while every subject in it was correctly formatted.
  // `wiki:` is the sync tool's own bookkeeping. It stays release-neutral on
  // purpose: a wiki sync should never be the reason a version ships.
  test.each<CommitCase>([
    {
      commits: bare('feat: add thing', 'feat(scope): add'),
      expected: 'minor',
      name: 'feat: → minor',
    },
    {
      commits: bare(
        'fix: a bug',
        'docs: typo',
        'chore(deps): bump',
        'refactor: clean',
        'perf: speed',
        'ci: pipeline',
        'test: cover',
        'style: lint'
      ),
      expected: 'patch',
      name: 'fix:/docs:/etc → patch',
    },
    {
      commits: bare('feat!: drop API', 'fix(scope)!: rename'),
      expected: 'major',
      name: '! suffix → major',
    },
    {
      commits: [{body: 'BREAKING CHANGE: removed thing', subject: 'feat: x'}],
      expected: 'major',
      name: 'BREAKING CHANGE in body → major',
    },
    {
      commits: bare('random commit', 'merged something'),
      expected: null,
      name: 'non-conventional → null',
    },
    {
      commits: bare('debt(cli): drain the backlog'),
      expected: 'patch',
      name: 'debt(cli): drain the backlog → patch',
    },
    {
      commits: bare('build(cli): rebundle the binary'),
      expected: 'patch',
      name: 'build(cli): rebundle the binary → patch',
    },
    {
      commits: bare('wiki: maintenance chain'),
      expected: null,
      name: 'wiki: → null (declared, but deliberately release-neutral)',
    },
    {
      commits: bare('spike: try a thing'),
      expected: null,
      name: 'a well-formed but undeclared type contributes nothing',
    },
    // Falsifiable, unlike asserting the return is `BumpKind | null` (which the
    // signature already guarantees): `feat` is the only minor, `wiki` the only
    // declared type that contributes nothing, and every other declared type has
    // to move the version.
    ...COMMIT_TYPES.map((type) => ({
      commits: bare(`${type}: thing`),
      expected: expectedBump(type),
      name: `${type}: has the intended bump disposition`,
    })),
  ])('$name', ({commits, expected}) => {
    for (const commit of commits) {
      expect(classifyCommit(commit)).toBe(expected);
    }
  });
});

describe('aggregateBump', () => {
  test.each<{
    commits: {body: string; subject: string}[];
    expected: null | string;
    name: string;
  }>([
    {
      commits: [
        {body: '', subject: 'fix: a'},
        {body: '', subject: 'feat: b'},
        {body: '', subject: 'docs: c'},
      ],
      expected: 'minor',
      name: 'highest severity wins',
    },
    {
      commits: [
        {body: '', subject: 'fix: a'},
        {body: '', subject: 'feat!: b'},
        {body: '', subject: 'feat: c'},
      ],
      expected: 'major',
      name: 'breaking trumps everything',
    },
    {
      commits: [
        {body: '', subject: 'fix: a'},
        {body: '', subject: 'chore: b'},
      ],
      expected: 'patch',
      name: 'all-patch → patch',
    },
    {
      commits: [
        {body: '', subject: 'random'},
        {body: '', subject: 'merge'},
      ],
      expected: null,
      name: 'no recognizable commits → null',
    },
  ])('$name', ({commits, expected}) => {
    expect(aggregateBump(commits)).toBe(expected);
  });
});

describe('applyBump', () => {
  test.each<{
    expected: string;
    kind: 'major' | 'minor' | 'patch';
    name: string;
  }>([
    {expected: '2.0.0', kind: 'major', name: 'major resets minor and patch'},
    {expected: '1.3.0', kind: 'minor', name: 'minor resets patch'},
    {expected: '1.2.4', kind: 'patch', name: 'patch increments patch'},
  ])('$name', ({expected, kind}) => {
    expect(applyBump('1.2.3', kind)).toBe(expected);
  });

  test('throws on non-semver', () => {
    expect(() => applyBump('not.a.version', 'patch')).toThrow(/not semver/);
    expect(() => applyBump('1.2', 'patch')).toThrow(/not semver/);
  });
});

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (currentVersion: string): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-bump-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  mkdirSync(path.join(root, '.gaia'), {recursive: true});
  writeFileSync(
    path.join(root, 'package.json'),
    `${JSON.stringify({name: 'gaia', version: currentVersion}, null, 2)}\n`,
    'utf8'
  );
  writeFileSync(
    path.join(root, '.gaia', 'VERSION'),
    `${currentVersion}\n`,
    'utf8'
  );

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const okResult = (stdout = ''): SpawnSyncReturns<string> => ({
  output: ['', stdout, ''] as never,
  pid: 0,
  signal: null,
  status: 0,
  stderr: '',
  stdout,
});

const failResult = (status: number): SpawnSyncReturns<string> => ({
  output: ['', '', ''] as never,
  pid: 0,
  signal: null,
  status,
  stderr: '',
  stdout: '',
});

const spawnErrorResult = (error: Error): SpawnSyncReturns<string> => ({
  error,
  output: ['', '', ''] as never,
  pid: 0,
  signal: null,
  status: null,
  stderr: '',
  stdout: '',
});

const buildLogOutput = (
  commits: {body?: string; subject: string}[]
): string => {
  const RECORD_SEPARATOR = '---END-COMMIT---';

  return commits
    .map(
      (commit) =>
        `${commit.subject}\n${commit.body ?? ''}\n${RECORD_SEPARATOR}\n`
    )
    .join('');
};

const buildRunner =
  (commits: {body?: string; subject: string}[]): CommandRunner =>
  (command, args) => {
    if (command === 'git' && args[0] === 'describe') {
      // Simulate "no tag yet"
      return failResult(128);
    }

    if (command === 'git' && args[0] === 'log') {
      return okResult(buildLogOutput(commits));
    }

    return okResult('');
  };

describe('defaultRunner', () => {
  // Asserted against a child that writes past Node's 1 MiB spawnSync default
  // rather than against the constant, so the test fails if the bound is
  // removed by any means.
  test('reads child stdout past the 1 MiB spawnSync default', () => {
    const size = 2 * 1024 * 1024;

    const result = defaultRunner(
      process.execPath,
      ['-e', `process.stdout.write('x'.repeat(${size}))`],
      {cwd: process.cwd()}
    );

    expect(result.error).toBeUndefined();
    expect(result.stdout).toHaveLength(size);
  });
});

const enobufsRunner: CommandRunner = () =>
  spawnErrorResult(new Error('spawnSync git ENOBUFS'));

describe('collectCommits', () => {
  // Pins the fail-closed contract: a spawn failure must block the release
  // rather than degrade to "no commits", which aggregates to no bump and
  // would propose the current version as if nothing had landed. The message
  // shape is expectSuccess's, not changelog.ts's inline result.error check.
  test('throws with the spawn error rather than returning no commits', () => {
    expect(() =>
      collectCommits('/nonexistent', enobufsRunner, 'v1.0.0..HEAD')
    ).toThrow('git log failed: spawnSync git ENOBUFS');
  });
});

describe('release bump CLI', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  // `files` maps a path under the sandbox root to its exact expected text
  // after the run; `setup` seeds anything beyond the default sandbox.
  test.each<{
    args: string[];
    commits: {subject: string}[];
    errContains: string;
    exit: number;
    files: Record<string, string>;
    name: string;
    setup: (root: string) => void;
    stdout: unknown;
    version: string;
  }>([
    {
      args: [],
      commits: [{subject: 'feat: add thing'}, {subject: 'fix: bug'}],
      errContains: '',
      exit: 0,
      // Proposing does NOT write.
      files: {
        '.gaia/VERSION': '1.2.3\n',
        'package.json': `${JSON.stringify({name: 'gaia', version: '1.2.3'}, null, 2)}\n`,
      },
      name: 'proposes minor bump when feat: present, without writing',
      setup: () => {},
      stdout: 'v1.2.3 -> v1.3.0 (minor)',
      version: '1.2.3',
    },
    {
      args: ['--auto'],
      commits: [{subject: 'fix: a'}, {subject: 'docs: b'}],
      errContains: '',
      exit: 0,
      files: {
        '.gaia/VERSION': '1.0.1\n',
        'package.json': `${JSON.stringify({name: 'gaia', version: '1.0.1'}, null, 2)}\n`,
      },
      name: '--auto applies a patch bump',
      setup: () => {},
      stdout: '1.0.1',
      version: '1.0.0',
    },
    {
      args: ['--auto'],
      commits: [{subject: 'fix: a'}],
      errContains: '',
      exit: 0,
      files: {
        'apps/web/package.json': `${JSON.stringify({name: 'web', version: '1.0.1'}, null, 2)}\n`,
      },
      name: '--auto keeps apps/web/package.json at the root version',
      setup: (root) => {
        mkdirSync(path.join(root, 'apps', 'web'), {recursive: true});
        writeFileSync(
          path.join(root, 'apps', 'web', 'package.json'),
          `${JSON.stringify({name: 'web', version: '1.0.0'}, null, 2)}\n`,
          'utf8'
        );
      },
      stdout: expect.any(String),
      version: '1.0.0',
    },
    {
      args: ['--auto'],
      commits: [{subject: 'feat!: rip out X'}],
      errContains: 'refusing --auto',
      exit: 1,
      files: {
        '.gaia/VERSION': '1.0.0\n',
        'package.json': `${JSON.stringify({name: 'gaia', version: '1.0.0'}, null, 2)}\n`,
      },
      name: '--auto refuses major without confirmation',
      setup: () => {},
      stdout: expect.any(String),
      version: '1.0.0',
    },
  ])(
    '$name',
    ({args, commits, errContains, exit, files, setup, stdout, version}) => {
      sandbox = setupSandbox(version);
      setup(sandbox.root);

      expect(run(args, {cwd: sandbox.root, runner: buildRunner(commits)})).toBe(
        exit
      );
      expect(stdio.outputs.join('').trim()).toEqual(stdout);
      expect(stdio.errors.join('')).toContain(errContains);

      for (const [file, text] of Object.entries(files)) {
        expect(readFileSync(path.join(sandbox.root, file), 'utf8')).toBe(text);
      }
    }
  );

  test.each<{
    args: string[];
    commits?: {subject: string}[];
    message: string;
    name: string;
  }>([
    {
      args: [],
      commits: [],
      message: 'no commits since last tag',
      name: 'exits 1 when no commits',
    },
    {
      args: [],
      commits: [{subject: 'random non-conventional commit'}],
      message: 'no conventional-commit prefixes',
      name: 'exits 1 when no conventional-commit prefixes',
    },
    {
      args: ['--bogus'],
      message: 'unknown flag',
      name: 'rejects unknown flags',
    },
  ])('$name', ({args, commits, message}) => {
    sandbox = setupSandbox('1.0.0');
    const runner = commits ? buildRunner(commits) : undefined;

    const exit = run(args, {cwd: sandbox.root, runner});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(message);
  });
});
