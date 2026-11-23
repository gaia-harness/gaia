import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from '../exit.js';
import type {GhOptions, GhResult} from '../util/run-process.js';
import {run} from './dismiss-alert.js';
import type {DismissAlertOptions} from './dismiss-alert.js';

const GITHUB_ORIGIN = 'git@github.com:acme/widgets.git';

type GhRunner = NonNullable<DismissAlertOptions['ghRunner']>;

let outputs: string[];

beforeEach(() => {
  outputs = [];
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    outputs.push(String(chunk));

    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
});

afterEach(() => {
  vi.restoreAllMocks();
});

const stdout = (): string => outputs.join('');
const result = (): Record<string, unknown> =>
  JSON.parse(stdout()) as Record<string, unknown>;

const SUCCESS: GhResult = {ok: true, stdout: '{}'};

const recordingGh = (
  response: GhResult = SUCCESS
): {calls: GhOptions[]; ghRunner: GhRunner} => {
  const calls: GhOptions[] = [];

  return {
    calls,
    ghRunner: async (options) => {
      calls.push(options);

      return response;
    },
  };
};

const validArgs = (overrides: string[] = []): string[] => [
  '--alert',
  '41',
  '--reason',
  'tolerable_risk',
  '--comment',
  'accepted by the team',
  '--confirmed',
  ...overrides,
];

// A later duplicate flag wins, so an override replaces the default value.
const withFlag = (flag: string, value: string): string[] => [
  ...validArgs().flatMap((token, index, all) =>
    token === flag || all[index - 1] === flag ? [] : [token]
  ),
  flag,
  value,
];

const dismiss = async (
  argv: string[],
  options: Partial<DismissAlertOptions> & {ghRunner: GhRunner}
): Promise<number> =>
  run(argv, {
    cwd: '/nonexistent-gaia-dismiss',
    originReader: () => GITHUB_ORIGIN,
    ...options,
  });

describe('dismiss-alert refusals send no request', () => {
  test.each(
    [
      {
        alert: 41,
        argv: validArgs().filter((token) => token !== '--confirmed'),
        error: 'not-confirmed',
        exit: 1,
        name: 'no --confirmed exits 1',
        origin: GITHUB_ORIGIN,
      },
      {
        alert: 41,
        argv: validArgs(),
        error: 'non-github-remote',
        exit: 1,
        name: 'a gitlab.com origin is non-github-remote',
        origin: 'git@gitlab.com:acme/widgets.git',
      },
      {
        alert: 41,
        argv: validArgs(),
        error: 'no-remote',
        exit: 1,
        name: 'a missing origin is no-remote',
        origin: null,
      },
      {
        alert: null,
        argv: withFlag('--alert', 'abc'),
        error: 'invalid-arguments',
        exit: EXIT_CODES.INVALID_ARGUMENTS,
        name: 'alert abc is invalid-arguments and exits 2',
        origin: GITHUB_ORIGIN,
      },
      {
        alert: null,
        argv: withFlag('--alert', '0'),
        error: 'invalid-arguments',
        exit: EXIT_CODES.INVALID_ARGUMENTS,
        name: 'alert 0 is invalid-arguments and exits 2',
        origin: GITHUB_ORIGIN,
      },
      {
        alert: null,
        argv: withFlag('--alert', '1.5'),
        error: 'invalid-arguments',
        exit: EXIT_CODES.INVALID_ARGUMENTS,
        name: 'alert 1.5 is invalid-arguments and exits 2',
        origin: GITHUB_ORIGIN,
      },
      {
        alert: null,
        argv: withFlag('--reason', 'fix_started'),
        error: 'invalid-arguments',
        exit: EXIT_CODES.INVALID_ARGUMENTS,
        name: 'reason fix_started is invalid-arguments and exits 2',
        origin: GITHUB_ORIGIN,
      },
      {
        alert: null,
        argv: withFlag('--comment', 'x'.repeat(300)),
        error: 'invalid-arguments',
        exit: EXIT_CODES.INVALID_ARGUMENTS,
        name: 'a 300 character comment is invalid-arguments and exits 2',
        origin: GITHUB_ORIGIN,
      },
      {
        alert: null,
        argv: withFlag('--comment', 'y'.repeat(281)),
        error: 'invalid-arguments',
        exit: EXIT_CODES.INVALID_ARGUMENTS,
        name: 'an over-long 281 character comment is invalid-arguments and exits 2',
        origin: GITHUB_ORIGIN,
      },
      {
        alert: null,
        argv: withFlag('--comment', ''),
        error: 'invalid-arguments',
        exit: EXIT_CODES.INVALID_ARGUMENTS,
        name: 'an empty comment is invalid-arguments and exits 2',
        origin: GITHUB_ORIGIN,
      },
      {
        alert: null,
        argv: validArgs(['--bogus', 'x']),
        error: 'invalid-arguments',
        exit: EXIT_CODES.INVALID_ARGUMENTS,
        name: 'an unknown flag is invalid-arguments and exits 2',
        origin: GITHUB_ORIGIN,
      },
    ].map((row) => [row.name, row] as const)
  )('%s', async (_name, {alert, argv, error, exit, origin}) => {
    const {calls, ghRunner} = recordingGh();
    const exitCode = await dismiss(argv, {
      ghRunner,
      originReader: () => origin,
    });

    expect(exitCode).toBe(exit);
    expect(result()).toStrictEqual({alert, dismissed: false, error});
    expect(calls).toHaveLength(0);
  });
});

describe('dismiss-alert request', () => {
  test('a valid 280 character comment sends exactly one PATCH as an argv array', async () => {
    const comment = 'c'.repeat(280);
    const {calls, ghRunner} = recordingGh();
    const exit = await dismiss(withFlag('--comment', comment), {ghRunner});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(result()).toStrictEqual({alert: 41, dismissed: true});
    expect(calls).toHaveLength(1);
    expect(calls[0]?.args).toStrictEqual([
      'api',
      '-X',
      'PATCH',
      'repos/acme/widgets/dependabot/alerts/41',
      '-f',
      'state=dismissed',
      '-f',
      'dismissed_reason=tolerable_risk',
      '-f',
      `dismissed_comment=${comment}`,
    ]);
  });

  test('the comment length counts code points, not UTF-16 units', async () => {
    const {calls, ghRunner} = recordingGh();
    const exit = await dismiss(withFlag('--comment', '\u{1F600}'.repeat(280)), {
      ghRunner,
    });

    expect(exit).toBe(EXIT_CODES.OK);
    expect(calls).toHaveLength(1);
  });

  test.each(
    (
      [
        {
          error: 'forbidden',
          name: 'HTTP 403 is forbidden, the call carries a timeout, and stderr never reaches stdout',
          response: {
            exitCode: 1,
            ok: false,
            stderr: 'gh: Forbidden (HTTP 403) token ghp_secret',
          },
        },
        {
          error: 'request-failed',
          name: 'a timed out call is request-failed even if its stderr mentions 403',
          response: {
            exitCode: -1,
            ok: false,
            stderr: 'HTTP 403',
            timedOut: true,
          },
        },
        {
          error: 'request-failed',
          name: 'any other failure is request-failed and echoes no stderr',
          response: {exitCode: 1, ok: false, stderr: 'HTTP 500 ghp_secret'},
        },
      ] satisfies {error: string; name: string; response: GhResult}[]
    ).map((row) => [row.name, row] as const)
  )('%s', async (_name, {error, response}) => {
    const {calls, ghRunner} = recordingGh(response);
    const exit = await dismiss(validArgs(), {ghRunner});

    expect(exit).toBe(1);
    expect(result()).toStrictEqual({alert: 41, dismissed: false, error});
    expect(stdout()).not.toContain('ghp_secret');
    expect(calls[0]?.timeoutMs).toBe(60_000);
  });

  test('--help prints usage naming the verb and exits 0', async () => {
    const {ghRunner} = recordingGh();

    expect(await dismiss(['--help'], {ghRunner})).toBe(EXIT_CODES.OK);
    expect(stdout()).toContain('Usage: gaia update-deps dismiss-alert');
  });
});
