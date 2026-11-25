/**
 * Strategy: stand up a real (empty) git repo so
 * `git rev-parse --show-toplevel` resolves the sandbox root, then inject a
 * fake `CommandRunner` that returns canned `SpawnSyncReturns<string>` values
 * keyed off argv. Each test asserts the handler's exit code and the exact
 * sequence of git/gh invocations the fake observed.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import type {SpawnSyncReturns} from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './chain.js';
import type {CommandRunner} from './util/branch.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-chain-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});
  writeFileSync(path.join(root, 'wiki', 'log.md'), '---\n---\n', 'utf8');

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

type RecordedCall = {
  args: string[];
  command: string;
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

const matches = (
  argv: readonly string[],
  command: string,
  observed: readonly string[]
): boolean => {
  const target = [command, ...argv];
  const seen = [command, ...observed];

  return (
    target.length === seen.length &&
    target.every((token, index) => token === seen[index])
  );
};

const PR_URL = 'https://github.com/gaia/example/pull/42';

const buildRunner =
  (
    scripted: {
      argv: readonly string[];
      result: SpawnSyncReturns<string>;
    }[],
    recorded: RecordedCall[]
  ): CommandRunner =>
  (command, args) => {
    recorded.push({args: [...args], command});
    const match = scripted.find((entry) => matches(entry.argv, command, args));

    if (match !== undefined) return match.result;

    // A land opens its pull request with `gh pr create`, which prints the URL
    // the review check reads the number from.
    if (command === 'gh' && args[0] === 'pr' && args[1] === 'create') {
      return okResult(`${PR_URL}\n`);
    }

    return okResult('');
  };

const gitCalls = (recorded: RecordedCall[]): RecordedCall[] =>
  recorded.filter((entry) => entry.command === 'git');

const ghCalls = (recorded: RecordedCall[]): RecordedCall[] =>
  recorded.filter((entry) => entry.command === 'gh');

const USAGE_SCRIPT = '.gaia/scripts/usage.sh';

// A fixed clock: 05:32 UTC on 2026-05-07, the timestamp `begin` mints and an
// in-place `commit` stamps.
const NOW = new Date('2026-05-07T05:32:00Z');
const NOW_SUBJECT = 'wiki: 2026-05-07 05:32 UTC';

const recordCalls = (recorded: RecordedCall[]): RecordedCall[] =>
  recorded.filter(
    (entry) => entry.command === 'bash' && entry.args[0] === USAGE_SCRIPT
  );

const cachePathOf = (root: string): string =>
  path.join(root, '.gaia', 'local', 'cache', 'shared', 'update-check.json');

const seedCache = (root: string): string => {
  mkdirSync(path.dirname(cachePathOf(root)), {recursive: true});
  const seeded = JSON.stringify({
    checkedAt: 1_700_000_000,
    wikiDriftCount: 31,
  });
  writeFileSync(cachePathOf(root), seeded, 'utf8');

  return seeded;
};

const wikiOnlyStatus = {
  argv: ['status', '--porcelain=v1', '-z', '-uall'],
  result: okResult(' M wiki/log.md\0'),
};

const finishLanding = (cwd: string, runner: CommandRunner): number =>
  run(['finish'], {
    cwd,
    runner,
  });

const statusCalls = (recorded: RecordedCall[]): RecordedCall[] =>
  ghCalls(recorded).filter(
    (entry) =>
      entry.args[0] === 'api' &&
      entry.args.some((token) => token.includes('/statuses/'))
  );

const mergeCalls = (recorded: RecordedCall[]): RecordedCall[] =>
  ghCalls(recorded).filter(
    (entry) => entry.args[0] === 'pr' && entry.args[1] === 'merge'
  );

const gateArgv = (root: string, pr: string): string[] => [
  '.gaia/scripts/pr-review-gate.sh',
  'check',
  '--root',
  root,
  '--pr',
  pr,
  '--out-of-scope',
];
const gateCalls = (recorded: RecordedCall[]): RecordedCall[] =>
  recorded.filter(
    (entry) =>
      entry.command === 'bash' &&
      entry.args[0] === '.gaia/scripts/pr-review-gate.sh'
  );
const refusedBeforeMerge = (recorded: RecordedCall[]): boolean =>
  mergeCalls(recorded).length === 0 &&
  statusCalls(recorded).length === 0 &&
  !ghCalls(recorded).some(
    (entry) => entry.args[0] === 'pr' && entry.args[1] === 'ready'
  );

describe('wiki chain', () => {
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

  describe('begin', () => {
    test('on a feature branch: no-op, exit 0, no branch cut', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('feature/x\n'),
          },
        ],
        recorded
      );

      const exit = run(['begin'], {cwd: sandbox.root, runner});
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'chain begin: in-place on feature/x'
      );
      expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
    });

    test.each(
      Array.of<{
        args: string[];
        error: string;
        name: string;
        scripted: Parameters<typeof buildRunner>[0];
      }>(
        {
          args: ['begin'],
          error:
            'refusing to start a wiki run on main; run /gaia-wiki, which isolates the run',
          name: 'on main: exit 1, no branch cut, names the isolating command',
          scripted: [
            {
              argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
              result: okResult('main\n'),
            },
          ],
        },
        {
          args: ['begin', '--branch-aware'],
          error: 'unknown flag: --branch-aware',
          name: 'rejects the retired --branch-aware flag rather than cutting a branch',
          scripted: [],
        },
        {
          args: ['begin'],
          error: 'refusing to start a wiki run on main',
          name: 'treats master like main',
          scripted: [
            {
              argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
              result: okResult('master\n'),
            },
          ],
        },
        {
          args: ['begin', '--bogus'],
          error: 'unknown flag',
          name: 'rejects unknown flag',
          scripted: [],
        }
      ).map((row) => [row.name, row] as const)
    )('%s', (_name, {args, error, scripted}) => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(scripted, recorded);

      const exit = run(args, {cwd: sandbox.root, runner});
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain(error);
      expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
    });
  });

  describe('commit', () => {
    test('with only wiki changes: add + commit, exit 0', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('feature/x\n'),
          },
          {
            argv: ['status', '--porcelain=v1', '-z', '-uall'],
            result: okResult(' M wiki/log.md\0?? wiki/meta/lint-report.md\0'),
          },
        ],
        recorded
      );

      const exit = run(['commit'], {
        cwd: sandbox.root,
        now: NOW,
        runner,
      });
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(`chain commit: ${NOW_SUBJECT}`);
      const verbs = gitCalls(recorded);
      expect(verbs.at(-2)).toMatchObject({
        args: ['add', 'wiki'],
        command: 'git',
      });
      expect(verbs.at(-1)).toMatchObject({
        args: ['commit', '-m', NOW_SUBJECT],
        command: 'git',
      });
      expect(ghCalls(recorded)).toHaveLength(0);
    });

    test('with no wiki changes: graceful no-op, exit 0', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('feature/x\n'),
          },
          {
            argv: ['status', '--porcelain=v1', '-z', '-uall'],
            result: okResult(''),
          },
        ],
        recorded
      );

      const exit = run(['commit'], {
        cwd: sandbox.root,
        now: NOW,
        runner,
      });
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'chain commit: nothing to commit'
      );
      expect(recorded.find((c) => c.args[0] === 'commit')).toBeUndefined();
    });

    test('rejects any argument: exit 1, no commit', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner([], recorded);
      const exit = run(['commit', '--label', 'wiki: x'], {
        cwd: sandbox.root,
        runner,
      });
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain('commit takes no arguments');
      expect(recorded).toHaveLength(0);
    });

    test('on a wiki branch: the subject carries the branch timestamp, not the clock', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('wiki/2026-05-06-2359\n'),
          },
          wikiOnlyStatus,
        ],
        recorded
      );

      const exit = run(['commit'], {cwd: sandbox.root, now: NOW, runner});
      expect(exit).toBe(0);
      expect(gitCalls(recorded).at(-1)).toMatchObject({
        args: ['commit', '-m', 'wiki: 2026-05-06 23:59 UTC'],
        command: 'git',
      });
    });

    test('commit failure unstages wiki and exits 2', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('feature/x\n'),
          },
          {
            argv: ['status', '--porcelain=v1', '-z', '-uall'],
            result: okResult(' M wiki/log.md\0'),
          },
          {argv: ['add', 'wiki'], result: okResult('')},
          {
            argv: ['commit', '-m', NOW_SUBJECT],
            result: failResult(1, 'nothing to commit'),
          },
        ],
        recorded
      );

      const exit = run(['commit'], {
        cwd: sandbox.root,
        now: NOW,
        runner,
      });
      expect(exit).toBe(2);
      expect(gitCalls(recorded)).toContainEqual({
        args: ['reset', 'HEAD', '--', 'wiki'],
        command: 'git',
      });
    });

    test('a successful commit sets checkedAt to 0 and keeps wikiDriftCount', () => {
      sandbox = setupSandbox();
      seedCache(sandbox.root);
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('feature/x\n'),
          },
          wikiOnlyStatus,
        ],
        recorded
      );

      const exit = run(['commit'], {
        cwd: sandbox.root,
        now: NOW,
        runner,
      });
      expect(exit).toBe(0);
      expect(gitCalls(recorded)).toContainEqual({
        args: ['commit', '-m', NOW_SUBJECT],
        command: 'git',
      });
      expect(
        JSON.parse(readFileSync(cachePathOf(sandbox.root), 'utf8'))
      ).toEqual({checkedAt: 0, wikiDriftCount: 31});
    });

    test.each(
      Array.of<{
        error: string;
        exit: number;
        name: string;
        scripted: Parameters<typeof buildRunner>[0];
      }>(
        {
          error: 'non-wiki changes',
          exit: 1,
          name: 'with non-wiki changes: exit 1, no commit',
          scripted: [
            {
              argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
              result: okResult('feature/x\n'),
            },
            {
              argv: ['status', '--porcelain=v1', '-z', '-uall'],
              result: okResult(' M app/foo.ts\0 M wiki/log.md\0'),
            },
          ],
        },
        ...['main', 'master'].map((protectedBranch) => ({
          error: `chain commit: refusing to commit on ${protectedBranch}; run /gaia-wiki, which isolates the run on its own wiki branch, or switch to a non-protected branch`,
          exit: 1,
          name: `on ${protectedBranch}: refuses, records no add or commit, leaves the cache untouched`,
          scripted: [
            {
              argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
              result: okResult(`${protectedBranch}\n`),
            },
            wikiOnlyStatus,
          ],
        })),
        {
          error: 'fatal: not a git repository',
          exit: 2,
          name: 'a branch read failure exits 2 and commits nothing',
          scripted: [
            {
              argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
              result: failResult(128, 'fatal: not a git repository'),
            },
            wikiOnlyStatus,
          ],
        }
      ).map((row) => [row.name, row] as const)
    )('%s', (_name, {error, exit: expectedExit, scripted}) => {
      sandbox = setupSandbox();
      const seeded = seedCache(sandbox.root);
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(scripted, recorded);

      const exit = run(['commit'], {cwd: sandbox.root, now: NOW, runner});
      expect(exit).toBe(expectedExit);
      expect(stdio.errors.join('')).toContain(error);
      expect(recorded.find((c) => c.args[0] === 'add')).toBeUndefined();
      expect(recorded.find((c) => c.args[0] === 'commit')).toBeUndefined();
      expect(readFileSync(cachePathOf(sandbox.root), 'utf8')).toBe(seeded);
    });

    test.each(
      Array.of<{
        absentVerbs: string[];
        exit: number;
        name: string;
        outputs: string[];
        presentCalls: RecordedCall[];
        scripted: Parameters<typeof buildRunner>[0];
      }>(
        {
          absentVerbs: ['commit'],
          exit: 1,
          name: 'the non-wiki refusal leaves the cache untouched',
          outputs: [],
          presentCalls: [],
          scripted: [
            {
              argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
              result: okResult('feature/x\n'),
            },
            {
              argv: ['status', '--porcelain=v1', '-z', '-uall'],
              result: okResult(' M app/foo.ts\0 M wiki/log.md\0'),
            },
          ],
        },
        {
          absentVerbs: ['commit'],
          exit: 0,
          name: 'the nothing-to-commit no-op leaves the cache untouched',
          outputs: ['chain commit: nothing to commit'],
          presentCalls: [],
          scripted: [
            {
              argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
              result: okResult('feature/x\n'),
            },
            {
              argv: ['status', '--porcelain=v1', '-z', '-uall'],
              result: okResult(''),
            },
          ],
        },
        {
          absentVerbs: [],
          exit: 2,
          name: 'a failed git commit leaves the cache untouched and unstages wiki',
          outputs: [],
          presentCalls: [
            {args: ['reset', 'HEAD', '--', 'wiki'], command: 'git'},
          ],
          scripted: [
            {
              argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
              result: okResult('feature/x\n'),
            },
            wikiOnlyStatus,
            {
              argv: ['commit', '-m', NOW_SUBJECT],
              result: failResult(1, 'hook rejected'),
            },
          ],
        }
      ).map((row) => [row.name, row] as const)
    )(
      '%s',
      (
        _name,
        {absentVerbs, exit: expectedExit, outputs, presentCalls, scripted}
      ) => {
        sandbox = setupSandbox();
        const seeded = seedCache(sandbox.root);
        const recorded: RecordedCall[] = [];
        const runner = buildRunner(scripted, recorded);

        const exit = run(['commit'], {cwd: sandbox.root, now: NOW, runner});
        expect(exit).toBe(expectedExit);

        for (const output of outputs) {
          expect(stdio.outputs.join('')).toContain(output);
        }

        for (const verb of absentVerbs) {
          expect(recorded.find((c) => c.args[0] === verb)).toBeUndefined();
        }

        for (const call of presentCalls) {
          expect(gitCalls(recorded)).toContainEqual(call);
        }

        expect(readFileSync(cachePathOf(sandbox.root), 'utf8')).toBe(seeded);
      }
    );
  });

  describe('finish', () => {
    test.each(
      Array.of<{branch: string; name: string; outputs: string[]}>(
        {
          branch: 'wiki/docs-cleanup',
          name: 'on a hand-named wiki/<slug> branch: stays in place, no push or gh call',
          outputs: [
            'chain finish: in-place commits remain on wiki/docs-cleanup',
          ],
        },
        {
          branch: 'feature/x',
          name: 'on a non-chain branch: no-op, exit 0, no PR',
          outputs: ['chain finish: in-place commits remain on feature/x'],
        },
        {
          branch: 'wiki-sync/2026-05-07-bbbbbbb',
          name: 'on a wiki-sync/ branch: treated as hand-named, no PR opened',
          outputs: [],
        }
      ).map((row) => [row.name, row] as const)
    )('%s', (_name, {branch, outputs}) => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult(`${branch}\n`),
          },
        ],
        recorded
      );

      const exit = run(['finish'], {cwd: sandbox.root, runner});
      expect(exit).toBe(0);

      for (const output of outputs) {
        expect(stdio.outputs.join('')).toContain(output);
      }

      expect(ghCalls(recorded)).toHaveLength(0);
      expect(recorded.find((c) => c.args[0] === 'push')).toBeUndefined();
    });

    test('on a chain branch: push + PR + auto-merge, then stays on the branch without waiting or cleaning up', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('wiki/2026-05-07-0532\n'),
          },
          {
            argv: ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
            result: okResult('origin/main\n'),
          },
          {
            argv: ['rev-list', '--count', 'origin/main..HEAD'],
            result: okResult('3\n'),
          },
          {
            argv: ['rev-parse', 'HEAD'],
            result: okResult('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'),
          },
        ],
        recorded
      );

      const exit = run(['finish'], {
        cwd: sandbox.root,
        runner,
      });
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'for wiki/2026-05-07-0532; auto-merge queued, merge not yet confirmed'
      );

      const ordered = recorded.map((c) => [c.command, ...c.args].join(' '));
      const pushIndex = ordered.findIndex((c) =>
        c.startsWith('git push -u origin wiki/2026-05-07-0532')
      );
      const prCreateIndex = ordered.findIndex((c) =>
        c.startsWith('gh pr create')
      );
      const prMergeIndex = ordered.indexOf(
        'gh pr merge --squash --auto --delete-branch'
      );
      expect(pushIndex).toBeGreaterThanOrEqual(0);
      expect(prCreateIndex).toBeGreaterThan(pushIndex);
      expect(prMergeIndex).toBeGreaterThan(prCreateIndex);
      // The merge wait and the local cleanup belong to the work lifecycle.
      expect(
        ghCalls(recorded).some(
          (c) =>
            c.args[0] === 'pr' &&
            c.args[1] === 'view' &&
            c.args.includes('state')
        )
      ).toBe(false);
      expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
      expect(recorded.find((c) => c.args[0] === 'pull')).toBeUndefined();
      expect(recorded.find((c) => c.args[0] === 'branch')).toBeUndefined();
    });

    describe('the PR review gate before auto-merge', () => {
      const chainBranch = 'wiki/2026-05-07-0532';
      const branchScript = [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult(`${chainBranch}\n`),
        },
        {
          argv: ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
          result: okResult('origin/main\n'),
        },
        {
          argv: ['rev-list', '--count', 'origin/main..HEAD'],
          result: okResult('3\n'),
        },
      ];
      test('an incomplete review prints the gate line, exits non-zero, and runs no ready, stamp or merge', () => {
        sandbox = setupSandbox();
        const recorded: RecordedCall[] = [];
        const runner = buildRunner(
          [
            ...branchScript,
            {
              argv: gateArgv(realpathSync(sandbox.root), '42'),
              result: {
                ...okResult('PR review: no review record.\n'),
                status: 1,
              },
            },
          ],
          recorded
        );

        const exit = finishLanding(sandbox.root, runner);

        expect(exit).not.toBe(0);
        expect(stdio.errors.join('')).toContain('PR review: no review record.');
        expect(gateCalls(recorded)).toHaveLength(1);
        expect(refusedBeforeMerge(recorded)).toBe(true);
      });

      test('a gate that could not run prints the could-not-be-checked line and queues no merge', () => {
        sandbox = setupSandbox();
        const recorded: RecordedCall[] = [];
        const runner = buildRunner(
          [
            ...branchScript,
            {
              argv: gateArgv(realpathSync(sandbox.root), '42'),
              result: failResult(2, 'jq missing'),
            },
          ],
          recorded
        );

        const exit = finishLanding(sandbox.root, runner);

        expect(exit).not.toBe(0);
        expect(stdio.errors.join('')).toContain(
          'PR review: could not be checked on PR #42 (jq missing).'
        );
        expect(refusedBeforeMerge(recorded)).toBe(true);
      });

      test('an already open pull request is reused: no gh pr create, and the gate runs with its number', () => {
        sandbox = setupSandbox();
        const recorded: RecordedCall[] = [];
        const runner = buildRunner(
          [
            ...branchScript,
            {
              argv: ['pr', 'view', chainBranch, '--json', 'number,url,state'],
              result: okResult(
                JSON.stringify({
                  number: 77,
                  state: 'OPEN',
                  url: 'https://github.com/gaia/example/pull/77',
                })
              ),
            },
            {
              argv: gateArgv(realpathSync(sandbox.root), '77'),
              result: {...okResult('PR review: incomplete.\n'), status: 1},
            },
          ],
          recorded
        );

        const exit = finishLanding(sandbox.root, runner);

        expect(exit).not.toBe(0);
        expect(
          ghCalls(recorded).some(
            (entry) => entry.args[0] === 'pr' && entry.args[1] === 'create'
          )
        ).toBe(false);
        expect(gateCalls(recorded)).toHaveLength(1);
        expect(gateCalls(recorded)[0]?.args[5]).toBe('77');
        expect(refusedBeforeMerge(recorded)).toBe(true);
      });
    });

    test.each(
      Array.of<{
        absentVerbs: string[];
        branch: string;
        name: string;
        output: string;
        presentCalls: RecordedCall[];
        status: string;
      }>(
        {
          absentVerbs: [],
          branch: 'wiki/2026-05-07-0533',
          name: 'on a chain branch with no commits ahead: drop empty branch, no PR',
          output: 'removed empty branch wiki/2026-05-07-0533',
          presentCalls: [
            {args: ['checkout', 'main'], command: 'git'},
            {args: ['branch', '-D', 'wiki/2026-05-07-0533'], command: 'git'},
          ],
          status: '',
        },
        {
          absentVerbs: ['checkout', 'branch'],
          branch: 'wiki/2026-05-07-0535',
          name: 'empty chain branch with a dirty tree: left in place, no delete',
          output: 'has uncommitted changes and no commits',
          presentCalls: [],
          status: ' M wiki/log.md\0',
        }
      ).map((row) => [row.name, row] as const)
    )('%s', (_name, {absentVerbs, branch, output, presentCalls, status}) => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult(`${branch}\n`),
          },
          {
            argv: ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
            result: okResult('origin/main\n'),
          },
          {
            argv: ['rev-list', '--count', 'origin/main..HEAD'],
            result: okResult('0\n'),
          },
          {
            argv: ['status', '--porcelain=v1', '-z', '-uall'],
            result: okResult(status),
          },
        ],
        recorded
      );

      const exit = run(['finish'], {cwd: sandbox.root, runner});
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(output);

      for (const verb of absentVerbs) {
        expect(recorded.find((c) => c.args[0] === verb)).toBeUndefined();
      }

      for (const call of presentCalls) {
        expect(gitCalls(recorded)).toContainEqual(call);
      }

      expect(ghCalls(recorded)).toHaveLength(0);
    });

    test('empty chain branch in a linked worktree: no checkout or delete, left to the caller', () => {
      sandbox = setupSandbox();
      execFileSync(
        'git',
        [
          '-c',
          'user.name=t',
          '-c',
          'user.email=t@example.com',
          'commit',
          '-q',
          '--allow-empty',
          '-m',
          'init',
        ],
        {cwd: sandbox.root}
      );
      const worktreeRoot = `${sandbox.root}-wt`;
      execFileSync(
        'git',
        ['worktree', 'add', '-q', '-b', 'wiki/2026-05-07-0536', worktreeRoot],
        {cwd: sandbox.root}
      );
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('wiki/2026-05-07-0536\n'),
          },
          {
            argv: ['rev-list', '--count', 'origin/main..HEAD'],
            result: okResult('0\n'),
          },
        ],
        recorded
      );

      try {
        const exit = run(['finish'], {cwd: worktreeRoot, runner});
        expect(exit).toBe(0);
        expect(stdio.outputs.join('')).toContain(
          'wiki/2026-05-07-0536 is held by a linked worktree, left for the caller to remove'
        );
        expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
        expect(recorded.find((c) => c.args[0] === 'branch')).toBeUndefined();
        expect(ghCalls(recorded)).toHaveLength(0);
      } finally {
        rmSync(worktreeRoot, {force: true, recursive: true});
      }
    });

    test('with no remote base ref: counts against the local base', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('wiki/2026-05-07-0537\n'),
          },
          {
            argv: [
              'rev-parse',
              '--verify',
              '--quiet',
              'refs/remotes/origin/main',
            ],
            result: failResult(1, ''),
          },
          {
            argv: ['rev-list', '--count', 'main..HEAD'],
            result: okResult('0\n'),
          },
        ],
        recorded
      );

      const exit = run(['finish'], {cwd: sandbox.root, runner});
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'removed empty branch wiki/2026-05-07-0537'
      );
      expect(gitCalls(recorded)).toContainEqual({
        args: ['rev-list', '--count', 'main..HEAD'],
        command: 'git',
      });
    });

    test('push failure short-circuits before any gh call, exit 2', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('wiki/2026-05-07-0534\n'),
          },
          {
            argv: ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
            result: okResult('origin/main\n'),
          },
          {
            argv: ['rev-list', '--count', 'origin/main..HEAD'],
            result: okResult('2\n'),
          },
          {
            argv: ['rev-parse', 'HEAD'],
            result: okResult('dddddddddddddddddddddddddddddddddddddddd\n'),
          },
          {
            argv: ['push', '-u', 'origin', 'wiki/2026-05-07-0534'],
            result: failResult(128, 'remote: rejected'),
          },
        ],
        recorded
      );

      const exit = run(['finish'], {cwd: sandbox.root, runner});
      expect(exit).toBe(2);
      expect(stdio.errors.join('')).toContain('remote: rejected');
      expect(ghCalls(recorded)).toHaveLength(0);
      expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
    });

    test('rejects unknown flag', () => {
      sandbox = setupSandbox();
      const exit = run(['finish', '--bogus'], {cwd: sandbox.root});
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain('unknown flag');
    });
  });

  describe('no subcommand writes the cost record', () => {
    // The /gaia-wiki playbook records the run once the merge wait returns, so
    // the recorded interval covers the wait; a record here would close it early.
    const currentBranch = (branch: string) => ({
      argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
      result: okResult(`${branch}\n`),
    });
    const aheadOfBase = (count: string) => [
      {
        argv: ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
        result: okResult('origin/main\n'),
      },
      {
        argv: ['rev-list', '--count', 'origin/main..HEAD'],
        result: okResult(`${count}\n`),
      },
    ];

    test.each(
      Array.of<{
        name: string;
        scenarios: {
          args: string[];
          exit: number;
          scripted: Parameters<typeof buildRunner>[0];
        }[];
      }>(
        {
          name: 'makes zero record calls, refused on main or in place',
          scenarios: [
            {
              args: ['begin'],
              exit: 0,
              scripted: [currentBranch('feature/x')],
            },
            {args: ['begin'], exit: 1, scripted: [currentBranch('main')]},
          ],
        },
        {
          name: 'makes zero record calls, committing or no-op',
          scenarios: [
            {
              args: ['commit'],
              exit: 0,
              scripted: [
                currentBranch('feature/x'),
                {
                  argv: ['status', '--porcelain=v1', '-z', '-uall'],
                  result: okResult(' M wiki/log.md\0'),
                },
              ],
            },
            {
              args: ['commit'],
              exit: 0,
              scripted: [
                currentBranch('feature/x'),
                {
                  argv: ['status', '--porcelain=v1', '-z', '-uall'],
                  result: okResult(''),
                },
              ],
            },
          ],
        },
        {
          name: 'a landed PR: no record call and no Cost line',
          scenarios: [
            {
              args: ['finish'],
              exit: 0,
              scripted: [
                currentBranch('wiki/2026-05-07-0532'),
                ...aheadOfBase('3'),
                {
                  argv: ['rev-parse', 'HEAD'],
                  result: okResult(
                    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
                  ),
                },
                {
                  argv: [
                    'pr',
                    'create',
                    '--draft',
                    '--title',
                    'wiki: 2026-05-07 05:32 UTC',
                    '--body',
                    'Automated /gaia-wiki landing (sync + consolidate + lint) via `gaia wiki chain finish`.',
                  ],
                  result: okResult(
                    'https://github.com/gaia-react/gaia/pull/712\n'
                  ),
                },
                {
                  argv: [
                    'pr',
                    'view',
                    'wiki/2026-05-07-0532',
                    '--json',
                    'state',
                    '--jq',
                    '.state',
                  ],
                  result: okResult('MERGED\n'),
                },
              ],
            },
          ],
        },
        {
          name: 'an empty branch: no record call and no Cost line',
          scenarios: [
            {
              args: ['finish'],
              exit: 0,
              scripted: [
                currentBranch('wiki/2026-05-07-0533'),
                ...aheadOfBase('0'),
              ],
            },
          ],
        },
        {
          name: 'an in-place branch: no record call and no Cost line',
          scenarios: [
            {
              args: ['finish'],
              exit: 0,
              scripted: [currentBranch('feature/x')],
            },
          ],
        }
      ).map((row) => [row.name, row] as const)
    )('%s', (_name, {scenarios}) => {
      sandbox = setupSandbox();

      for (const {args, exit: expectedExit, scripted} of scenarios) {
        const recorded: RecordedCall[] = [];
        const runner = buildRunner(scripted, recorded);

        const exit = run(args, {cwd: sandbox.root, now: NOW, runner});
        expect(exit).toBe(expectedExit);
        expect(recordCalls(recorded)).toHaveLength(0);
      }

      expect(stdio.outputs.join('')).not.toContain('Cost:');
    });
  });

  describe('finish: out-of-scope stamp and statusline cache', () => {
    const BRANCH = 'wiki/2026-05-07-0532';
    const HEAD_SHA = 'b'.repeat(40);

    const prRecord = (
      paths: readonly string[],
      headRefOid: string = HEAD_SHA
    ): SpawnSyncReturns<string> =>
      okResult(
        JSON.stringify({
          baseRefName: 'main',
          files: paths.map((filePath) => ({path: filePath})),
          headRefOid,
        })
      );

    const finishRunner = (
      recorded: RecordedCall[],
      options: {
        draftState?: SpawnSyncReturns<string>;
        post?: SpawnSyncReturns<string>;
        push?: SpawnSyncReturns<string>;
        ready?: SpawnSyncReturns<string>;
        record?: SpawnSyncReturns<string>;
        resolver?: SpawnSyncReturns<string>;
        visibility?: SpawnSyncReturns<string>;
      } = {}
    ): CommandRunner =>
      buildRunner(
        [
          {
            argv: [
              'repo',
              'view',
              '--json',
              'visibility',
              '--jq',
              '.visibility',
            ],
            result: options.visibility ?? okResult('PUBLIC\n'),
          },
          {
            argv: [
              'pr',
              'view',
              BRANCH,
              '--json',
              'isDraft',
              '--jq',
              '.isDraft',
            ],
            result: options.draftState ?? okResult('true\n'),
          },
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult(`${BRANCH}\n`),
          },
          {
            argv: ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
            result: okResult('origin/main\n'),
          },
          {
            argv: ['rev-list', '--count', 'origin/main..HEAD'],
            result: okResult('3\n'),
          },
          {argv: ['rev-parse', 'HEAD'], result: okResult(`${HEAD_SHA}\n`)},
          {
            argv: [
              'pr',
              'view',
              BRANCH,
              '--json',
              'files,headRefOid,baseRefName',
            ],
            result: options.record ?? prRecord(['wiki/log.md']),
          },
          {argv: ['fetch', 'origin', 'main'], result: okResult('')},
          {
            argv: [
              '.gaia/scripts/resolve-audit-members.sh',
              '--root',
              // `resolveRepoRoot` returns the realpath, and the macOS tmpdir
              // is a symlink.
              realpathSync(sandbox.root),
              '--base',
              'origin/main',
            ],
            result: options.resolver ?? okResult(''),
          },
          {
            argv: [
              'api',
              '-X',
              'POST',
              `repos/{owner}/{repo}/statuses/${HEAD_SHA}`,
              '-f',
              'state=success',
              '-f',
              'context=GAIA-Audit',
              '-f',
              'description=skipped: out of scope',
            ],
            result: options.post ?? okResult(''),
          },
          {
            argv: ['pr', 'ready', BRANCH],
            result: options.ready ?? okResult(''),
          },
          {
            argv: ['push', '-u', 'origin', BRANCH],
            result: options.push ?? okResult(''),
          },
        ],
        recorded
      );

    test('a wiki-only diff posts the stamp after pr create and before pr merge', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];

      expect(finishLanding(sandbox.root, finishRunner(recorded))).toBe(0);

      const ordered = recorded.map((c) => [c.command, ...c.args].join(' '));
      const createIndex = ordered.findIndex((c) =>
        c.startsWith('gh pr create')
      );
      const stampIndex = ordered.findIndex((c) =>
        c.includes(`/statuses/${HEAD_SHA}`)
      );
      const mergeIndex = ordered.indexOf(
        'gh pr merge --squash --auto --delete-branch'
      );
      expect(statusCalls(recorded)).toHaveLength(1);
      expect(stampIndex).toBeGreaterThan(createIndex);
      expect(mergeIndex).toBeGreaterThan(stampIndex);
    });

    test('the pull request is created as a draft and marked ready only after the stamp posts, before auto-merge', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];

      expect(finishLanding(sandbox.root, finishRunner(recorded))).toBe(0);

      const ordered = recorded.map((c) => [c.command, ...c.args].join(' '));
      const createIndex = ordered.findIndex((c) =>
        c.startsWith('gh pr create')
      );
      const stampIndex = ordered.findIndex((c) =>
        c.includes(`/statuses/${HEAD_SHA}`)
      );
      const readyIndex = ordered.indexOf(`gh pr ready ${BRANCH}`);
      const mergeIndex = ordered.indexOf(
        'gh pr merge --squash --auto --delete-branch'
      );
      expect(ordered[createIndex]).toContain(' --draft ');
      expect(readyIndex).toBeGreaterThan(stampIndex);
      expect(mergeIndex).toBeGreaterThan(readyIndex);
    });

    test('a private repository opens the pull request ready and skips the ready flip', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];

      expect(
        finishLanding(
          sandbox.root,
          finishRunner(recorded, {
            draftState: okResult('false\n'),
            visibility: okResult('PRIVATE\n'),
          })
        )
      ).toBe(0);

      const createCall = ghCalls(recorded).find(
        (entry) => entry.args[0] === 'pr' && entry.args[1] === 'create'
      );
      expect(createCall?.args).not.toContain('--draft');
      expect(statusCalls(recorded)).toHaveLength(1);
      expect(
        ghCalls(recorded).some(
          (entry) => entry.args[0] === 'pr' && entry.args[1] === 'ready'
        )
      ).toBe(false);
      expect(mergeCalls(recorded)).toHaveLength(1);
    });

    test('a draft create refused for unsupported drafts is retried once without --draft', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const inner = finishRunner(recorded, {draftState: okResult('false\n')});

      const runner: CommandRunner = (command, args, spawnOptions) => {
        if (
          command === 'gh' &&
          args[1] === 'create' &&
          args.includes('--draft')
        ) {
          recorded.push({args: [...args], command});

          return failResult(1, 'Draft pull requests are not supported');
        }

        return inner(command, args, spawnOptions);
      };

      expect(finishLanding(sandbox.root, runner)).toBe(0);

      const creates = ghCalls(recorded).filter(
        (entry) => entry.args[0] === 'pr' && entry.args[1] === 'create'
      );
      expect(creates).toHaveLength(2);
      expect(creates[1]?.args).not.toContain('--draft');
      expect(mergeCalls(recorded)).toHaveLength(1);
    });

    test('a pull request whose stamp did not post is never marked ready', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];

      finishLanding(
        sandbox.root,
        finishRunner(recorded, {resolver: okResult('code-audit-frontend\n')})
      );
      expect(
        ghCalls(recorded).some(
          (entry) => entry.args[0] === 'pr' && entry.args[1] === 'ready'
        )
      ).toBe(false);
    });

    test('a failed ready flip keeps the posted status, skips auto-merge and names the manual command', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];

      const exit = finishLanding(
        sandbox.root,
        finishRunner(recorded, {ready: failResult(1, 'GraphQL: forbidden')})
      );
      expect(exit).toBe(1);
      expect(statusCalls(recorded)).toHaveLength(1);
      expect(mergeCalls(recorded)).toHaveLength(0);
      expect(stdio.errors.join('')).toContain('GraphQL: forbidden');
      expect(stdio.errors.join('')).toContain(`gh pr ready ${BRANCH}`);
    });

    test.each(
      Array.of<{
        errors: string[];
        name: string;
        options: Parameters<typeof finishRunner>[1];
        statusCallCount: number;
      }>(
        {
          errors: ['outside wiki/'],
          name: 'a pull request path outside wiki/ posts nothing and still lands',
          options: {
            record: prRecord(['wiki/log.md', 'app/ahead-of-origin.ts']),
          },
          statusCallCount: 0,
        },
        {
          errors: ['not the commit this checkout'],
          name: 'a pull request head that is not the local HEAD posts nothing and still lands',
          options: {record: prRecord(['wiki/log.md'], 'e'.repeat(40))},
          statusCallCount: 0,
        },
        {
          errors: ['could not read the pull request'],
          name: 'a pull request record that cannot be read posts nothing and still lands',
          options: {record: failResult(1, 'HTTP 502')},
          statusCallCount: 0,
        },
        {
          errors: ['code-audit-frontend'],
          name: 'a dispatched roster member refuses the post, names the member, and still lands',
          options: {resolver: okResult('code-audit-frontend\n')},
          statusCallCount: 0,
        },
        {
          errors: ['could not answer'],
          name: 'a resolver that cannot answer refuses the post and still lands',
          options: {resolver: failResult(2, 'no auditors roster')},
          statusCallCount: 0,
        },
        {
          errors: ['HTTP 403', 'PR Merge Workflow'],
          name: 'a failing status POST leaves the exit code unchanged and names the manual path',
          options: {post: failResult(1, 'HTTP 403')},
          statusCallCount: 1,
        }
      ).map((row) => [row.name, row] as const)
    )('%s', (_name, {errors, options, statusCallCount}) => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];

      const exit = finishLanding(sandbox.root, finishRunner(recorded, options));
      expect(exit).toBe(0);
      expect(statusCalls(recorded)).toHaveLength(statusCallCount);
      expect(mergeCalls(recorded)).toHaveLength(1);

      for (const error of errors) {
        expect(stdio.errors.join('')).toContain(error);
      }
    });

    test('reads the pull request, never a local diff, and resolves members against the fetched remote base', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];

      expect(finishLanding(sandbox.root, finishRunner(recorded))).toBe(0);
      expect(
        recorded.some((c) => c.command === 'git' && c.args[0] === 'diff')
      ).toBe(false);
      const resolverCall = recorded.find((c) =>
        c.args.includes('.gaia/scripts/resolve-audit-members.sh')
      );
      expect(resolverCall?.args.at(-1)).toBe('origin/main');
    });

    // The main checkout's state file has not advanced until the merge lands
    // and cleanup pulls it, so the cache is refreshed then, not here.
    test.each(
      Array.of<{
        exit: number;
        name: string;
        options: Parameters<typeof finishRunner>[1];
      }>(
        {
          exit: 0,
          name: 'a queued land leaves the cache untouched',
          options: {},
        },
        {
          exit: 2,
          name: 'a push failure leaves the cache untouched',
          options: {push: failResult(128, 'remote: rejected')},
        }
      ).map((row) => [row.name, row] as const)
    )('%s', (_name, {exit, options}) => {
      sandbox = setupSandbox();
      mkdirSync(path.dirname(cachePathOf(sandbox.root)), {recursive: true});
      const seeded = JSON.stringify({
        checkedAt: 1_700_000_000,
        wikiDriftCount: 27,
      });
      writeFileSync(cachePathOf(sandbox.root), seeded, 'utf8');

      expect(finishLanding(sandbox.root, finishRunner([], options))).toBe(exit);
      expect(readFileSync(cachePathOf(sandbox.root), 'utf8')).toBe(seeded);
    });
  });

  describe('dispatch', () => {
    test('--help prints usage without invoking git', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner([], recorded);

      const exit = run(['--help'], {cwd: sandbox.root, runner});
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain('Usage:');
      expect(recorded).toHaveLength(0);
    });

    test('refresh-nudge with no statusline cache: exit 0, says so, creates nothing', () => {
      sandbox = setupSandbox();

      const exit = run(['refresh-nudge'], {cwd: sandbox.root});
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'chain refresh-nudge: no statusline cache to refresh'
      );
      expect(existsSync(cachePathOf(sandbox.root))).toBe(false);
    });

    test.each(
      [
        {
          args: ['refresh-nudge', '--force'],
          error: 'takes no arguments',
          name: 'refresh-nudge rejects arguments: exit 1',
        },
        {
          args: ['bogus'],
          error: 'unknown wiki chain action',
          name: 'unknown action: exit 1',
        },
      ].map((row) => [row.name, row] as const)
    )('%s', (_name, {args, error}) => {
      sandbox = setupSandbox();

      expect(run(args, {cwd: sandbox.root})).toBe(1);
      expect(stdio.errors.join('')).toContain(error);
    });
  });
});
