/**
 * Mixes a real-git temp-repo fixture (for the commit dance) with mocked
 * runners (for the tag-push path, where pushing to a remote isn't
 * portable in CI).
 */
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
import {checkReleaseFence, run} from './commit-and-tag.js';
import type {CommandRunner} from './commit-and-tag.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (currentVersion: string): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-commit-tag-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});
  mkdirSync(path.join(root, '.gaia'), {recursive: true});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});
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
  writeFileSync(
    path.join(root, '.gaia', 'manifest.json'),
    `{"version":"${currentVersion}","files":{}}\n`,
    'utf8'
  );
  writeFileSync(
    path.join(root, 'CHANGELOG.md'),
    `# Changelog\n\n## [${currentVersion}] - 2026-05-07\n`,
    'utf8'
  );
  writeFileSync(path.join(root, 'wiki', 'log.md'), '# log\n', 'utf8');
  writeFileSync(
    path.join(root, 'wiki', '.state.json'),
    `${JSON.stringify({last_evaluated_sha: '0000000', version: 1}, null, 2)}\n`,
    'utf8'
  );

  // Seed a baseline commit so HEAD exists before --commit runs.
  writeFileSync(path.join(root, 'README.md'), '# repo\n', 'utf8');
  execFileSync('git', ['add', 'README.md'], {cwd: root});
  execFileSync('git', ['commit', '-q', '-m', 'init'], {cwd: root});

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

const failResult = (
  status: number,
  stderr: string
): SpawnSyncReturns<string> => ({
  output: ['', '', stderr] as never,
  pid: 0,
  signal: null,
  status,
  stderr,
  stdout: '',
});

const callLinesOf = (recorded: {args: string[]; command: string}[]): string[] =>
  recorded.map((call) => `${call.command} ${call.args.join(' ')}`);

type RecordedCall = {
  args: string[];
  command: string;
};

const buildRecordingRunner =
  (
    scripted: {
      argv: readonly string[];
      result: SpawnSyncReturns<string>;
    }[],
    recorded: RecordedCall[]
  ): CommandRunner =>
  (command, args) => {
    recorded.push({args: [...args], command});

    for (const entry of scripted) {
      if (entry.argv.length === args.length) {
        let match = true;

        for (let index = 0; index < entry.argv.length; index += 1) {
          if (entry.argv[index] !== args[index]) {
            match = false;
            break;
          }
        }

        if (match) return entry.result;
      }
    }

    return okResult('');
  };

describe('release commit-and-tag --commit', () => {
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

  test(
    'stages release files, commits, amends state SHA against real git',
    {timeout: 30_000},
    () => {
      sandbox = setupSandbox('1.2.0');

      const exit = run(['--commit'], {cwd: sandbox.root});
      expect(exit).toBe(0);
      const out = stdio.outputs.join('');
      expect(out).toContain('commit-and-tag: committed v1.2.0');

      // Verify the commit lives in the log with the expected message.
      const logOut = execFileSync('git', ['log', '--oneline'], {
        cwd: sandbox.root,
        encoding: 'utf8',
      });
      expect(logOut).toContain('chore(release): v1.2.0');

      // Verify wiki/.state.json was updated away from the seeded "0000000".
      // (The pre-amend SHA is captured into the file and the amend rewrites
      // HEAD to a new SHA; matching the post-amend HEAD is impossible by
      // construction. The contract is that the file points at the
      // pre-amend release commit, which is not in the log after amend but
      // IS the parent SHA the runbook documents.)
      const state = JSON.parse(
        readFileSync(path.join(sandbox.root, 'wiki/.state.json'), 'utf8')
      ) as {last_evaluated_sha: string};
      expect(state.last_evaluated_sha).not.toBe('0000000');
      expect(state.last_evaluated_sha).toMatch(/^[\da-f]{40}$/u);

      // Tree should be clean (everything committed via amend).
      const status = execFileSync('git', ['status', '--porcelain=v1'], {
        cwd: sandbox.root,
        encoding: 'utf8',
      });
      expect(status.trim()).toBe('');

      // The printed SHA names the amended release commit the tag and push act
      // on, not the pre-amend one the state file records.
      const head = execFileSync('git', ['rev-parse', 'HEAD'], {
        cwd: sandbox.root,
        encoding: 'utf8',
      }).trim();
      expect(out).toContain(`committed v1.2.0 (${head.slice(0, 7)})`);
      expect(head).not.toBe(state.last_evaluated_sha);
    }
  );

  test('does not stage wiki/hot.md', {timeout: 30_000}, () => {
    sandbox = setupSandbox('1.2.0');
    writeFileSync(path.join(sandbox.root, 'wiki', 'hot.md'), '# hot\n', 'utf8');

    const exit = run(['--commit'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const committed = execFileSync(
      'git',
      ['show', '--name-only', '--pretty=format:', 'HEAD'],
      {cwd: sandbox.root, encoding: 'utf8'}
    );
    expect(committed).toContain('wiki/log.md');
    expect(committed).not.toContain('wiki/hot.md');
  });

  test.each<{
    args: string[];
    exits: number[];
    message: string;
    name: string;
    runner?: CommandRunner;
    setup: (root: string) => void;
    version: string;
  }>([
    {
      args: ['--commit'],
      exits: [0, 1],
      message: '',
      name: 'exit 1 when no release files exist to stage',
      setup: (root) => {
        rmSync(path.join(root, '.gaia'), {force: true, recursive: true});
        rmSync(path.join(root, 'wiki'), {force: true, recursive: true});
        rmSync(path.join(root, 'CHANGELOG.md'));
        // package.json must remain so readVersion succeeds. It is still a
        // release file, so the run may stage it and succeed.
      },
      version: '1.0.0',
    },
    {
      args: ['--commit'],
      exits: [2],
      message: 'amend blocked by hook',
      name: 'exits non-zero when the state-SHA amend fails',
      runner: buildRecordingRunner(
        [
          {argv: ['rev-parse', 'HEAD'], result: okResult('abc1234def\n')},
          {
            argv: ['commit', '--amend', '--no-edit'],
            result: failResult(1, 'fatal: amend blocked by hook'),
          },
        ],
        []
      ),
      setup: () => {},
      version: '1.4.0',
    },
    {
      args: ['--tag'],
      exits: [1],
      message: 'package.json not found',
      name: 'exit 1 when package.json is missing',
      setup: (root) => {
        rmSync(path.join(root, 'package.json'));
      },
      version: '1.0.0',
    },
  ])('$name', ({args, exits, message, runner, setup, version}) => {
    sandbox = setupSandbox(version);
    setup(sandbox.root);

    expect(exits).toContain(run(args, {cwd: sandbox.root, runner}));
    expect(stdio.errors.join('')).toContain(message);
  });
});

describe('release commit-and-tag --tag', () => {
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

  test.each<{
    args: string[];
    calls: string[];
    errContains: string;
    exit: number;
    failing?: {argv: string[]; status: number; stderr: string};
    name: string;
    outContains: string[];
    pushAttempted: boolean;
  }>([
    {
      args: ['--tag'],
      calls: ['git tag -a v2.5.1 -m Release v2.5.1', 'git push origin v2.5.1'],
      errContains: '',
      exit: 0,
      name: 'tags HEAD and pushes the tag (default)',
      outContains: ['tagged v2.5.1', 'pushed'],
      pushAttempted: true,
    },
    {
      args: ['--tag', '--no-push'],
      calls: [],
      errContains: '',
      exit: 0,
      name: '--no-push skips push step',
      outContains: ['push skipped'],
      pushAttempted: false,
    },
    {
      args: ['--tag'],
      calls: [],
      errContains: 'tag exists',
      exit: 2,
      failing: {
        argv: ['tag', '-a', 'v2.5.1', '-m', 'Release v2.5.1'],
        status: 128,
        stderr: 'fatal: tag exists',
      },
      name: 'exit 2 on git tag failure',
      outContains: [],
      pushAttempted: false,
    },
    {
      args: ['--tag'],
      calls: [],
      errContains: 'unable to access remote',
      exit: 2,
      failing: {
        argv: ['push', 'origin', 'v2.5.1'],
        status: 1,
        stderr: 'fatal: unable to access remote',
      },
      name: 'exits non-zero when the push fails',
      outContains: [],
      pushAttempted: true,
    },
  ])(
    '$name',
    ({args, calls, errContains, exit, failing, outContains, pushAttempted}) => {
      sandbox = setupSandbox('2.5.1');
      const recorded: RecordedCall[] = [];
      const runner = buildRecordingRunner(
        failing ?
          [
            {
              argv: failing.argv,
              result: failResult(failing.status, failing.stderr),
            },
          ]
        : [],
        recorded
      );

      expect(run(args, {cwd: sandbox.root, runner})).toBe(exit);
      expect(stdio.errors.join('')).toContain(errContains);

      for (const text of outContains) {
        expect(stdio.outputs.join('')).toContain(text);
      }

      for (const call of calls) {
        expect(callLinesOf(recorded)).toContain(call);
      }
      // Push runs only when the tag succeeds and --no-push is absent.
      expect(recorded.some((c) => c.args[0] === 'push')).toBe(pushAttempted);
    }
  );
});

const LOCAL_TAGS_ARGV = ['tag', '-l', 'v*'] as const;
const REMOTE_TAGS_ARGV = ['ls-remote', '--tags', 'origin'] as const;

const remoteLines = (...names: string[]): string =>
  names
    .map(
      (name) => `0123456789abcdef0123456789abcdef01234567\trefs/tags/${name}`
    )
    .join('\n');

const callLines = (recorded: RecordedCall[]): string[] =>
  recorded.map((call) => `${call.command} ${call.args.join(' ')}`);

describe('release commit-and-tag --tag release fence', () => {
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

  const ANY_TEXT = /.*/su;
  const REFUSED = /^REFUSED:/mu;
  const failedOriginRead = {
    argv: REMOTE_TAGS_ARGV,
    result: failResult(128, 'fatal: could not read from remote'),
  };

  test.each<{
    args: string[];
    errAbsent: string[];
    errContains: string[];
    errPattern: RegExp;
    exit: number;
    gaiaVersion: string;
    name: string;
    scripted: {argv: readonly string[]; result: SpawnSyncReturns<string>}[];
    tagCalls: string[];
    version: string;
  }>([
    {
      args: ['--tag'],
      errAbsent: [],
      errContains: [
        'v1.6.2',
        'v2.0.0',
        'newest-created release',
        'Nothing was tagged',
      ],
      errPattern: REFUSED,
      exit: 1,
      gaiaVersion: '2.0.1',
      name: 'refuses a lower major than the highest origin tag',
      scripted: [
        {argv: REMOTE_TAGS_ARGV, result: okResult(remoteLines('v2.0.0'))},
      ],
      tagCalls: [],
      version: '1.6.2',
    },
    {
      args: ['--tag'],
      errAbsent: [],
      errContains: [],
      errPattern: ANY_TEXT,
      exit: 0,
      gaiaVersion: '2.0.1',
      name: 'tags an equal major',
      scripted: [
        {argv: REMOTE_TAGS_ARGV, result: okResult(remoteLines('v2.0.0'))},
      ],
      tagCalls: [
        'git tag -a v2.0.1 -m Release v2.0.1',
        'git push origin v2.0.1',
      ],
      version: '2.0.1',
    },
    {
      args: ['--tag'],
      errAbsent: [],
      errContains: [],
      errPattern: ANY_TEXT,
      exit: 0,
      gaiaVersion: '1.6.2',
      name: 'spec tags play no part in the highest major',
      scripted: [
        {
          argv: REMOTE_TAGS_ARGV,
          result: okResult(remoteLines('spec/99', 'spec/120', 'v1.6.1')),
        },
      ],
      tagCalls: ['git tag -a v1.6.2 -m Release v1.6.2'],
      version: '1.6.2',
    },
    {
      args: ['--tag'],
      errAbsent: ['^{}'],
      errContains: ['v2.0.0'],
      errPattern: ANY_TEXT,
      exit: 1,
      gaiaVersion: '1.6.2',
      name: 'peeled lines are dropped and the tag still counts once',
      scripted: [
        {
          argv: REMOTE_TAGS_ARGV,
          result: okResult(remoteLines('v2.0.0', 'v2.0.0^{}')),
        },
      ],
      tagCalls: [],
      version: '1.6.2',
    },
    {
      args: ['--tag'],
      errAbsent: [],
      errContains: [],
      errPattern: ANY_TEXT,
      exit: 0,
      gaiaVersion: '1.6.2',
      name: 'a peeled-only line never counts as a release tag',
      scripted: [
        {argv: REMOTE_TAGS_ARGV, result: okResult(remoteLines('v2.0.0^{}'))},
      ],
      tagCalls: [],
      version: '1.6.2',
    },
    {
      args: ['--tag'],
      errAbsent: [],
      errContains: ['v3.0.0'],
      errPattern: ANY_TEXT,
      exit: 1,
      gaiaVersion: '2.5.0',
      name: 'a tag present only locally counts',
      scripted: [{argv: LOCAL_TAGS_ARGV, result: okResult('v3.0.0\n')}],
      tagCalls: [],
      version: '2.5.0',
    },
    ...[false, true].map((noPush) => ({
      args: noPush ? ['--tag', '--no-push'] : ['--tag'],
      errAbsent: [] as string[],
      errContains: ['origin', 're-run'],
      errPattern: REFUSED,
      exit: 1,
      gaiaVersion: '2.5.0',
      name: `a failed origin read refuses with a next step (noPush=${String(noPush)})`,
      scripted: [failedOriginRead],
      tagCalls: [] as string[],
      version: '2.5.0',
    })),
    {
      args: ['--tag'],
      errAbsent: [],
      errContains: [],
      errPattern: ANY_TEXT,
      exit: 1,
      gaiaVersion: '2.5.0',
      name: 'a spawn error on the origin read refuses',
      scripted: [
        {
          argv: REMOTE_TAGS_ARGV,
          result: {
            ...failResult(0, ''),
            error: new Error('spawn git ENOENT'),
            status: null,
          },
        },
      ],
      tagCalls: [],
      version: '2.5.0',
    },
    {
      args: ['--tag'],
      errAbsent: [],
      errContains: ['not-a-version'],
      errPattern: ANY_TEXT,
      exit: 1,
      gaiaVersion: 'not-a-version',
      name: 'a package.json version with no parseable major refuses',
      scripted: [],
      tagCalls: [],
      version: 'not-a-version',
    },
  ])(
    '$name',
    ({
      args,
      errAbsent,
      errContains,
      errPattern,
      exit,
      gaiaVersion,
      scripted,
      tagCalls,
      version,
    }) => {
      sandbox = setupSandbox(version);
      writeFileSync(
        path.join(sandbox.root, '.gaia', 'VERSION'),
        `${gaiaVersion}\n`
      );
      const recorded: RecordedCall[] = [];
      const runner = buildRecordingRunner(scripted, recorded);

      expect(run(args, {cwd: sandbox.root, runner})).toBe(exit);
      const err = stdio.errors.join('');
      expect(err).toMatch(errPattern);
      for (const text of errContains) expect(err).toContain(text);
      for (const text of errAbsent) expect(err).not.toContain(text);
      for (const call of tagCalls) expect(callLines(recorded)).toContain(call);
      // A refused release never tags and never pushes.
      expect(
        recorded.some((c) => c.args[0] === 'tag' && c.args[1] === '-a')
      ).toBe(exit === 0);
      expect(recorded.some((c) => c.args[0] === 'push')).toBe(exit === 0);
    }
  );
});

describe('checkReleaseFence', () => {
  type FenceResult = ReturnType<typeof checkReleaseFence>;

  test.each<{
    checks: {expected: FenceResult; tags: string[]; version: string}[];
    name: string;
  }>([
    {
      checks: [
        {
          expected: {ok: true},
          tags: [
            'v2.0',
            'v2.0.0-rc.1',
            'v02.0.0',
            'release-3',
            'v3',
            'v3.0.0.1',
            'spec/9',
          ],
          version: '1.6.2',
        },
      ],
      name: 'ignores non-release names',
    },
    {
      checks: [
        {
          expected: {highestTag: 'v2.10.1', ok: false},
          tags: ['v2.0.0', 'v2.10.1', 'v2.9.0'],
          version: '1.6.2',
        },
      ],
      name: 'refuses and names the highest release tag by full version',
    },
    {
      checks: [
        {expected: {ok: true}, tags: ['v2.3.0'], version: '2.0.1'},
        {expected: {ok: true}, tags: ['v2.3.0'], version: '3.0.0'},
        {expected: {ok: true}, tags: [], version: '1.0.0'},
      ],
      name: 'proceeds on an equal or higher major, or with no tags',
    },
    {
      checks: [
        {
          expected: {ok: false, unparseable: true},
          tags: ['v1.0.0'],
          version: 'banana',
        },
      ],
      name: 'reports an unparseable version',
    },
  ])('$name', ({checks}) => {
    for (const {expected, tags, version} of checks) {
      expect(checkReleaseFence(version, tags)).toEqual(expected);
    }
  });
});

describe('argument validation', () => {
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

  test.each<{
    args: string[];
    exit: number;
    name: string;
    stream: 'errors' | 'outputs';
    text: string;
  }>([
    {
      args: [],
      exit: 1,
      name: 'requires --commit or --tag',
      stream: 'errors',
      text: 'one of --commit or --tag is required',
    },
    {
      args: ['--commit', '--tag'],
      exit: 1,
      name: 'rejects both --commit and --tag',
      stream: 'errors',
      text: 'mutually exclusive',
    },
    {
      args: ['--bogus'],
      exit: 1,
      name: 'rejects unknown flags',
      stream: 'errors',
      text: 'unknown flag',
    },
    {
      args: ['--help'],
      exit: 0,
      name: '--help prints usage',
      stream: 'outputs',
      text: 'Usage:',
    },
  ])('$name', ({args, exit, stream, text}) => {
    sandbox = setupSandbox('1.0.0');
    expect(run(args, {cwd: sandbox.root})).toBe(exit);
    expect(stdio[stream].join('')).toContain(text);
  });
});
