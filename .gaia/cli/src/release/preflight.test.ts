import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import type {SpawnSyncReturns} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './preflight.js';
import type {CommandRunner} from './preflight.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-preflight-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});

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

type RecordedCall = {
  args: string[];
  command: string;
};

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

/** A realistic full 40-char SHA: the value `gaia wiki state` records. */
const STATE_SHA = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
/** `git log` range query uses the resolved (full) SHA. */
const DRIFT_RANGE = `${STATE_SHA}..HEAD`;
/** `git rev-parse --verify` argument that resolves the state SHA. */
const REVPARSE_ARGS = ['rev-parse', '--verify', `${STATE_SHA}^{commit}`];

/**
 * The recovery baseline `gaia wiki state` reports as `suggested_base` when the
 * recorded SHA is orphaned (`reachable:false`), an abbreviated SHA, like
 * `state_sha`.
 */
const SUGGESTED_BASE = 'f6e5d4c3';
/** `rev-parse --verify` resolves the abbreviated recovery base to a full SHA. */
const SUGGESTED_FULL = 'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5';
const SUGGESTED_REVPARSE = [
  'rev-parse',
  '--verify',
  `${SUGGESTED_BASE}^{commit}`,
];
const SUGGESTED_RANGE = `${SUGGESTED_FULL}..HEAD`;

describe('release preflight', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  type Scripted = {
    argv: readonly string[];
    result: SpawnSyncReturns<string>;
  }[];

  const gitFailure = (stderr: string): SpawnSyncReturns<string> => ({
    output: ['', '', ''] as never,
    pid: 0,
    signal: null,
    status: 128,
    stderr,
    stdout: '',
  });

  // The two probes every preflight run makes before it looks at the wiki.
  const branchAndStatus = (branch: string, status = ''): Scripted => [
    {
      argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
      result: okResult(`${branch}\n`),
    },
    {argv: ['status', '--porcelain=v1', '-uall'], result: okResult(status)},
  ];

  const probeWith =
    (overrides: Record<string, unknown> = {}) =>
    () => ({
      commits_ahead: 0,
      drift_count: 0,
      reachable: true,
      state_sha: STATE_SHA,
      suggested_base: '',
      ...overrides,
    });

  test('exit 0 on main with clean tree and synced wiki', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        drift_count: 0,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(0);
    // Success: no stdout, no stderr.
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');
  });

  const THROWING_REVPARSE: Scripted = [
    {
      argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
      result: {
        error: new Error('git not found'),
        output: ['', '', ''] as never,
        pid: 0,
        signal: null,
        status: null,
        stderr: '',
        stdout: '',
      },
    },
  ];

  test.each<{
    exit: number;
    message: string;
    name: string;
    probe: Record<string, unknown>;
    rangesAbsent: string[];
    rangesSeen: string[];
    scripted: Scripted;
  }>([
    {
      exit: 1,
      message: 'must be on main',
      name: 'exit 1 when not on main',
      probe: {},
      rangesAbsent: [],
      rangesSeen: [],
      scripted: branchAndStatus('feature/x'),
    },
    {
      exit: 1,
      message: 'working tree is dirty',
      name: 'exit 1 when working tree is dirty',
      probe: {},
      rangesAbsent: [],
      rangesSeen: [],
      scripted: branchAndStatus('main', ' M README.md\n'),
    },
    {
      exit: 1,
      message: 'wiki is 2 commits behind HEAD',
      name: 'exit 1 when wiki is behind HEAD with substantive drift',
      probe: {commits_ahead: 2, drift_count: 2},
      rangesAbsent: [],
      rangesSeen: [],
      scripted: [
        ...branchAndStatus('main'),
        {argv: REVPARSE_ARGS, result: okResult(`${STATE_SHA}\n`)},
        {
          argv: ['log', '--format=%s', DRIFT_RANGE],
          result: okResult('feat: a new thing\nwiki: sync through abc1234\n'),
        },
      ],
    },
    {
      exit: 1,
      message: 'wiki is 2 commits behind HEAD',
      name: 'exit 1 when drift mixes a wiki artifact with a real commit',
      probe: {commits_ahead: 2, drift_count: 2},
      rangesAbsent: [],
      rangesSeen: [],
      scripted: [
        ...branchAndStatus('main'),
        {argv: REVPARSE_ARGS, result: okResult(`${STATE_SHA}\n`)},
        {
          argv: ['log', '--format=%s', DRIFT_RANGE],
          result: okResult('wiki: sync through abc1234\nfix: real bug\n'),
        },
      ],
    },
    {
      exit: 1,
      message: 'wiki is 1 commits behind HEAD',
      name: 'exit 1 when the state SHA cannot be resolved',
      probe: {commits_ahead: 1, drift_count: 1},
      rangesAbsent: [],
      rangesSeen: [],
      scripted: [
        ...branchAndStatus('main'),
        {
          argv: REVPARSE_ARGS,
          result: gitFailure('fatal: ambiguous argument'),
        },
      ],
    },
    {
      exit: 1,
      message: 'wiki is 1 commits behind HEAD',
      name: 'exit 1 when drift commit log cannot be read',
      probe: {commits_ahead: 1, drift_count: 1},
      rangesAbsent: [],
      rangesSeen: [],
      scripted: [
        ...branchAndStatus('main'),
        {argv: REVPARSE_ARGS, result: okResult(`${STATE_SHA}\n`)},
        {
          argv: ['log', '--format=%s', DRIFT_RANGE],
          result: gitFailure('fatal: bad revision'),
        },
      ],
    },
    {
      exit: 1,
      message: 'cannot determine wiki drift',
      name: 'exit 1 when the orphaned recovery base does not resolve, even at drift_count 0',
      probe: {
        reachable: false,
        suggested_base: SUGGESTED_BASE,
      },
      rangesAbsent: [],
      rangesSeen: [],
      scripted: [
        ...branchAndStatus('main'),
        {
          argv: SUGGESTED_REVPARSE,
          result: gitFailure('fatal: bad revision'),
        },
      ],
    },
    {
      // reachable:false is the normal post-squash-merge condition. `gaia wiki
      // state` hardcodes commits_ahead:0 there, so the gate must recover the
      // un-evaluated window from suggested_base..HEAD instead of reading the
      // zero. The orphaned state_sha range is topologically unreliable after a
      // squash; the gate inspects suggested_base..HEAD, never state_sha..HEAD.
      exit: 1,
      message: 'wiki is 2 commits behind HEAD',
      name: 'exit 1 when orphaned state recovers a window with substantive drift',
      probe: {
        drift_count: 2,
        reachable: false,
        suggested_base: SUGGESTED_BASE,
      },
      rangesAbsent: [DRIFT_RANGE],
      rangesSeen: [SUGGESTED_RANGE],
      scripted: [
        ...branchAndStatus('main'),
        {argv: SUGGESTED_REVPARSE, result: okResult(`${SUGGESTED_FULL}\n`)},
        {
          argv: ['log', '--format=%s', SUGGESTED_RANGE],
          result: okResult('feat: a real change\nwiki: sync through abc1234\n'),
        },
      ],
    },
    {
      exit: 2,
      message: 'preflight:',
      name: 'exit 2 when git rev-parse fails',
      probe: {},
      rangesAbsent: [],
      rangesSeen: [],
      scripted: THROWING_REVPARSE,
    },
  ])('$name', ({exit, message, probe, rangesAbsent, rangesSeen, scripted}) => {
    const recorded: RecordedCall[] = [];
    const code = run([], {
      cwd: sandbox.root,
      runner: buildRunner(scripted, recorded),
      wikiStateProbe: probeWith(probe),
    });
    expect(code).toBe(exit);
    expect(stdio.errors.join('')).toContain(message);

    for (const range of rangesSeen) {
      expect(recorded.some((call) => call.args.includes(range))).toBe(true);
    }

    for (const range of rangesAbsent) {
      expect(recorded.some((call) => call.args.includes(range))).toBe(false);
    }
  });

  // `errors` is either the exact empty string or a substring matcher.
  test.each<{
    errors: unknown;
    logRead: boolean;
    name: string;
    probe: Record<string, unknown>;
    scripted: Scripted;
  }>([
    {
      errors: expect.stringContaining('wiki-sync squash artifact'),
      logRead: true,
      name: 'exit 0 when drift is entirely wiki-sync squash artifacts',
      probe: {commits_ahead: 1, drift_count: 1},
      scripted: [
        ...branchAndStatus('main'),
        {argv: REVPARSE_ARGS, result: okResult(`${STATE_SHA}\n`)},
        {
          argv: ['log', '--format=%s', DRIFT_RANGE],
          result: okResult('wiki: sync through abc1234 (#173)\n'),
        },
      ],
    },
    {
      errors: expect.stringContaining('wiki-sync squash artifact'),
      logRead: true,
      name: 'exit 0 when orphaned recovered window is only wiki-sync artifacts',
      probe: {drift_count: 1, reachable: false, suggested_base: SUGGESTED_BASE},
      scripted: [
        ...branchAndStatus('main'),
        {argv: SUGGESTED_REVPARSE, result: okResult(`${SUGGESTED_FULL}\n`)},
        {
          argv: ['log', '--format=%s', SUGGESTED_RANGE],
          result: okResult('wiki: sync through abc1234 (#173)\n'),
        },
      ],
    },
    // suggested_base empty means the timestamp predates all history; there is
    // nothing un-evaluated to recover, so today's pass is preserved.
    {
      errors: '',
      logRead: false,
      name: 'exit 0 when orphaned state has no recoverable baseline',
      probe: {reachable: false, state_sha: ''},
      scripted: branchAndStatus('main'),
    },
    // `gaia wiki state` excludes bookkeeping subjects from drift_count, so a
    // window of nothing else arrives as 0 and needs no drift-log inspection.
    {
      errors: '',
      logRead: false,
      name: 'exit 0 when the orphaned recovered window holds only bookkeeping commits',
      probe: {reachable: false, suggested_base: SUGGESTED_BASE},
      scripted: [
        ...branchAndStatus('main'),
        {argv: SUGGESTED_REVPARSE, result: okResult(`${SUGGESTED_FULL}\n`)},
      ],
    },
  ])('$name', ({errors, logRead, probe, scripted}) => {
    const recorded: RecordedCall[] = [];
    const exit = run([], {
      cwd: sandbox.root,
      runner: buildRunner(scripted, recorded),
      wikiStateProbe: probeWith(probe),
    });
    expect(exit).toBe(0);
    expect(stdio.errors.join('')).toEqual(errors);
    expect(stdio.outputs.join('')).toBe('');
    expect(recorded.some((call) => call.args[0] === 'log')).toBe(logRead);
    // The count comes from the probe JSON; the gate never runs rev-list.
    expect(recorded.every((call) => call.args[0] !== 'rev-list')).toBe(true);
  });

  test.each<{
    line: string;
    name: string;
    probe: Record<string, unknown>;
    scripted: Scripted;
  }>([
    {
      line: 'cannot determine wiki drift',
      name: 'the unresolvable recovery base advice ends with the bare command',
      probe: {reachable: false, suggested_base: SUGGESTED_BASE},
      scripted: [
        ...branchAndStatus('main'),
        {
          argv: SUGGESTED_REVPARSE,
          result: gitFailure('fatal: bad revision'),
        },
      ],
    },
    {
      line: 'commits behind HEAD',
      name: 'the substantive drift advice ends with the bare command',
      probe: {commits_ahead: 2, drift_count: 2},
      scripted: [
        ...branchAndStatus('main'),
        {argv: REVPARSE_ARGS, result: okResult(`${STATE_SHA}\n`)},
        {
          argv: ['log', '--format=%s', DRIFT_RANGE],
          result: okResult('feat: a new thing\nwiki: sync through abc1234\n'),
        },
      ],
    },
  ])('$name', ({line, probe, scripted}) => {
    const exit = run([], {
      cwd: sandbox.root,
      runner: buildRunner(scripted, []),
      wikiStateProbe: probeWith(probe),
    });
    const refusalLine = stdio.errors
      .join('')
      .split('\n')
      .find((candidate) => candidate.includes(line));
    expect(exit).toBe(1);
    expect(refusalLine?.endsWith('; run /gaia-wiki first')).toBe(true);
  });

  test('reachable path ignores suggested_base and uses state_sha', () => {
    // Defensive regression: the recovery branch is gated on `!reachable`. Even
    // if a payload carried suggested_base while reachable, the count must come
    // from the JSON's commits_ahead and the range from state_sha; byte
    // identical to the pre-recovery behavior.
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
        {argv: REVPARSE_ARGS, result: okResult(`${STATE_SHA}\n`)},
        {
          argv: ['log', '--format=%s', DRIFT_RANGE],
          result: okResult('wiki: sync through abc1234\n'),
        },
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 1,
        drift_count: 1,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: SUGGESTED_BASE,
      }),
    });
    expect(exit).toBe(0);
    expect(stdio.errors.join('')).toContain('wiki-sync squash artifact');
    expect(recorded.some((call) => call.args.includes(DRIFT_RANGE))).toBe(true);
    expect(recorded.some((call) => call.args.includes(SUGGESTED_RANGE))).toBe(
      false
    );
    // Count comes from the JSON, so the reachable path never runs rev-list.
    expect(recorded.every((call) => call.args[0] !== 'rev-list')).toBe(true);
  });

  test.each<{
    args: string[];
    exit: number;
    name: string;
    stream: 'errors' | 'outputs';
    text: string;
  }>([
    {
      args: ['--branch', 'release/v1'],
      exit: 0,
      name: '--branch overrides allowed release branch',
      stream: 'errors',
      text: '',
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
    const code = run(args, {
      cwd: sandbox.root,
      runner: buildRunner(branchAndStatus('release/v1'), []),
      wikiStateProbe: probeWith(),
    });
    expect(code).toBe(exit);
    expect(stdio[stream].join('')).toContain(text);
  });
});
