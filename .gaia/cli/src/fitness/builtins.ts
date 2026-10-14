import {spawn} from 'node:child_process';
import {accessSync, constants, realpathSync, statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
/**
 * `gaia fitness builtins`: runs the Claude Code built-in checks (`claude
 * doctor`, `claude plugin validate`) bounded, and records each as `ran` or
 * `skipped` with a reason. Their output varies with the installed Claude Code
 * version and machine, so this never runs inside `check`.
 */
import {defaultRoot, parseRootArguments} from './cli-args.js';
import {discoverFiles} from './discover.js';
import {compareBytes} from './markdown.js';
import {redact, redactDeep} from './secrets.js';

/**
 * Each stream is kept to 256 KiB: a doctor report or a validate result is a few
 * KiB, so the cap only bites on a runaway child, and it keeps the printed JSON
 * small enough for a model to read whole.
 */
export const MAX_CAPTURE_BYTES = 256 * 1024;

/**
 * Sixty seconds: `claude doctor` starts the CLI and probes the install, which
 * takes a few seconds on a cold machine; a minute leaves headroom without
 * letting a hung child stall the run. `GAIA_FITNESS_BUILTIN_TIMEOUT_MS`
 * overrides it.
 */
export const DEFAULT_TIMEOUT_MS = 60_000;

export const TIMEOUT_ENV = 'GAIA_FITNESS_BUILTIN_TIMEOUT_MS';

export const TRUNCATION_MARKER = '\n[output truncated]';

/** The only variables a child sees; nothing else from the parent env. */
const ENV_ALLOWLIST = ['HOME', 'LANG', 'LC_ALL', 'PATH', 'TERM'] as const;

const NO_FILE_REASON = 'validated no file';
const NOT_ON_PATH_REASON = 'claude is not on PATH';
const NO_DIRECTORY_REASON = 'no skill, agent or command directory';
const UNSUPPORTED_REASON =
  'this claude version does not support plugin validate --json';

const UNKNOWN_FLAG_PATTERN =
  /unknown (?:command|option|subcommand)|unrecognized (?:command|option)|too many arguments/i;

const TARGET_DIRECTORY = /^(.*\/)?\.claude\/(?:agents|commands|skills)\//;

type BuiltinEntry = {
  exit_code?: number;
  name: string;
  output?: string;
  reason?: string;
  results?: ValidateResult[];
  status: 'ran' | 'skipped';
  targets?: string[];
};

type Spawned =
  | {
      exitCode: number;
      kind: 'exited';
      stderr: string;
      stdout: string;
    }
  | {kind: 'failed'; message: string}
  | {kind: 'timeout'};

type ValidateResult = {
  exit_code?: number;
  json?: unknown;
  reason?: string;
  status: 'ran' | 'skipped';
  target: string;
};

const isDirectory = (candidate: string): boolean => {
  try {
    return statSync(candidate).isDirectory();
  } catch {
    return false;
  }
};

const timeoutMilliseconds = (environment: NodeJS.ProcessEnv): number => {
  const raw = environment[TIMEOUT_ENV];
  const parsed = raw === undefined ? Number.NaN : Number(raw);

  return Number.isInteger(parsed) && parsed > 0 ? parsed : DEFAULT_TIMEOUT_MS;
};

/** A PATH walk: no shell, the first executable regular file named `claude`. */
export const findOnPath = (
  name: string,
  searchPath: string | undefined
): string | undefined => {
  for (const directory of (searchPath ?? '').split(path.delimiter)) {
    if (directory !== '') {
      const candidate = path.join(directory, name);

      try {
        if (statSync(candidate).isFile()) {
          accessSync(candidate, constants.X_OK);

          return candidate;
        }
      } catch {
        // not here; keep walking
      }
    }
  }

  return undefined;
};

const scrubbedEnvironment = (
  environment: NodeJS.ProcessEnv
): NodeJS.ProcessEnv => {
  const scrubbed: NodeJS.ProcessEnv = {};

  for (const key of ENV_ALLOWLIST) {
    const value = environment[key];

    if (value !== undefined) scrubbed[key] = value;
  }

  return scrubbed;
};

type Capture = {chunks: Buffer[]; size: number; truncated: boolean};

const append = (capture: Capture, chunk: Buffer): void => {
  const room = MAX_CAPTURE_BYTES - capture.size;

  if (room <= 0) {
    capture.truncated = true;

    return;
  }

  if (chunk.length > room) {
    capture.chunks.push(chunk.subarray(0, room));
    capture.size += room;
    capture.truncated = true;

    return;
  }

  capture.chunks.push(chunk);
  capture.size += chunk.length;
};

const captured = (capture: Capture): string =>
  `${Buffer.concat(capture.chunks).toString('utf8')}${
    capture.truncated ? TRUNCATION_MARKER : ''
  }`;

const killTree = (pid: number | undefined): void => {
  if (pid === undefined) return;

  try {
    process.kill(-pid, 'SIGKILL');
  } catch {
    try {
      process.kill(pid, 'SIGKILL');
    } catch {
      // already gone
    }
  }
};

/** Runs `executable args` in `root`: argv array, no shell, scrubbed env, capped output, bounded time. */
const spawnBounded = async ({
  args,
  environment,
  executable,
  root,
  timeoutMs,
}: {
  args: readonly string[];
  environment: NodeJS.ProcessEnv;
  executable: string;
  root: string;
  timeoutMs: number;
}): Promise<Spawned> =>
  new Promise((resolve) => {
    const stdout: Capture = {chunks: [], size: 0, truncated: false};
    const stderr: Capture = {chunks: [], size: 0, truncated: false};
    let settled = false;
    let timer: NodeJS.Timeout | undefined;

    const settle = (result: Spawned): void => {
      if (settled) return;
      settled = true;
      if (timer !== undefined) clearTimeout(timer);
      resolve(result);
    };

    const child = spawn(executable, [...args], {
      cwd: root,
      detached: true,
      env: scrubbedEnvironment(environment),
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    timer = setTimeout(() => {
      killTree(child.pid);
      settle({kind: 'timeout'});
    }, timeoutMs);

    child.stdout.on('data', (chunk: Buffer) => {
      append(stdout, chunk);
    });
    child.stderr.on('data', (chunk: Buffer) => {
      append(stderr, chunk);
    });
    child.on('error', (error: Error) => {
      settle({kind: 'failed', message: error.message});
    });
    child.on('close', (code: null | number) => {
      settle({
        exitCode: code ?? 1,
        kind: 'exited',
        stderr: captured(stderr),
        stdout: captured(stdout),
      });
    });
  });

const skipped = (name: string, reason: string): BuiltinEntry => ({
  name,
  reason,
  status: 'skipped',
});

type NotExited = Exclude<Spawned, {kind: 'exited'}>;

const didNotExit = (spawned: Spawned): spawned is NotExited =>
  spawned.kind !== 'exited';

const skipReasonOf = (spawned: NotExited, timeoutMs: number): string =>
  spawned.kind === 'timeout' ?
    `timed out after ${timeoutMs} ms`
  : `could not start claude: ${spawned.message}`;

const runDoctor = async (context: Context): Promise<BuiltinEntry> => {
  const spawned = await spawnBounded({
    args: ['doctor'],
    environment: context.environment,
    executable: context.executable,
    root: context.root,
    timeoutMs: context.timeoutMs,
  });

  if (didNotExit(spawned)) {
    return skipped('claude doctor', skipReasonOf(spawned, context.timeoutMs));
  }

  const output = [spawned.stdout, spawned.stderr]
    .filter((part) => part !== '')
    .join('\n');

  return {
    exit_code: spawned.exitCode,
    name: 'claude doctor',
    output: redact(output),
    status: 'ran',
  };
};

/** Every directory holding skills, agents or commands, repo-relative and sorted. */
export const findTargetDirectories = (root: string): string[] => {
  const directories = new Set<string>();

  for (const file of discoverFiles(root).files) {
    const match = TARGET_DIRECTORY.exec(file.path);

    if (match !== null) {
      const directory = file.path.slice(
        0,
        file.path.indexOf('/', (match[1]?.length ?? 0) + '.claude/'.length)
      );

      if (isDirectory(path.join(root, directory))) directories.add(directory);
    }
  }

  const found = [...directories];

  return found.toSorted(compareBytes);
};

/** Rewrites every string that starts with the root path to its repo-relative form. */
export const relativizeRoot = (
  value: unknown,
  roots: readonly string[]
): unknown => {
  if (typeof value === 'string') {
    for (const root of roots) {
      if (value === root) return '.';
      if (value.startsWith(`${root}/`)) return value.slice(root.length + 1);
    }

    return value;
  }

  if (Array.isArray(value))
    return value.map((item: unknown) => relativizeRoot(item, roots));

  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        relativizeRoot(item, roots),
      ])
    );
  }

  return value;
};

const parseJson = (text: string): unknown => {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return undefined;
  }
};

const hasContents = (json: unknown): boolean =>
  json !== null &&
  typeof json === 'object' &&
  Array.isArray((json as {contents?: unknown}).contents) &&
  (json as {contents: unknown[]}).contents.length > 0;

type Context = {
  environment: NodeJS.ProcessEnv;
  executable: string;
  root: string;
  timeoutMs: number;
};

const UNSUPPORTED = 'unsupported';

const validateTarget = async (
  context: Context,
  target: string,
  roots: readonly string[]
): Promise<typeof UNSUPPORTED | ValidateResult> => {
  const spawned = await spawnBounded({
    args: ['plugin', 'validate', target, '--json'],
    environment: context.environment,
    executable: context.executable,
    root: context.root,
    timeoutMs: context.timeoutMs,
  });

  if (didNotExit(spawned)) {
    return {
      reason: skipReasonOf(spawned, context.timeoutMs),
      status: 'skipped',
      target,
    };
  }

  const parsed = parseJson(spawned.stdout);

  if (parsed === undefined) {
    if (UNKNOWN_FLAG_PATTERN.test(`${spawned.stderr}\n${spawned.stdout}`)) {
      return UNSUPPORTED;
    }

    return {exit_code: spawned.exitCode, json: null, status: 'ran', target};
  }

  const json = relativizeRoot(parsed, roots);

  if (!hasContents(parsed)) {
    return {
      exit_code: spawned.exitCode,
      json,
      reason: NO_FILE_REASON,
      status: 'skipped',
      target,
    };
  }

  return {exit_code: spawned.exitCode, json, status: 'ran', target};
};

const runValidate = async (context: Context): Promise<BuiltinEntry> => {
  const name = 'claude plugin validate';
  const targets = findTargetDirectories(context.root);

  if (targets.length === 0) return skipped(name, NO_DIRECTORY_REASON);

  const roots = [...new Set([context.root, realpathSync(context.root)])];
  const outcomes = await Promise.all(
    targets.map(async (target) => validateTarget(context, target, roots))
  );
  const results: ValidateResult[] = [];

  for (const outcome of outcomes) {
    if (outcome === UNSUPPORTED) return skipped(name, UNSUPPORTED_REASON);
    results.push(outcome);
  }

  if (!results.some((result) => result.status === 'ran')) {
    const reasons = new Set(results.map((result) => result.reason));
    const [only] = [...reasons];

    return {
      name,
      reason: reasons.size === 1 && only !== undefined ? only : NO_FILE_REASON,
      results,
      status: 'skipped',
      targets,
    };
  }

  return {name, results, status: 'ran', targets};
};

export const runBuiltins = async ({
  environment,
  root,
}: {
  environment: NodeJS.ProcessEnv;
  root: string;
}): Promise<{builtins: BuiltinEntry[]}> => {
  const executable = findOnPath('claude', environment.PATH);

  if (executable === undefined) {
    return {
      builtins: [
        skipped('claude doctor', NOT_ON_PATH_REASON),
        skipped('claude plugin validate', NOT_ON_PATH_REASON),
      ],
    };
  }

  const context: Context = {
    environment,
    executable,
    root,
    timeoutMs: timeoutMilliseconds(environment),
  };

  return {
    builtins: [await runDoctor(context), await runValidate(context)],
  };
};

/** `gaia fitness builtins`: always exits 0 once it completed, whatever the built-ins returned. */
export const run = async (args: readonly string[]): Promise<number> => {
  const parsed = parseRootArguments(args);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'fitness builtins',
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }

  const root = path.resolve(parsed.root ?? defaultRoot());

  if (!isDirectory(root)) {
    structuredError({
      code: 'could_not_run',
      message: 'the root is not a directory',
      subcommand: 'fitness builtins',
    });

    return EXIT_CODES.COULD_NOT_RUN;
  }

  const report = await runBuiltins({environment: process.env, root});

  process.stdout.write(`${JSON.stringify(redactDeep(report), null, 2)}\n`);

  return EXIT_CODES.OK;
};
