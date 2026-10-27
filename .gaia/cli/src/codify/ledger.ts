/**
 * `gaia codify-ledger {list|record|lapsed|snapshot}`
 *
 * The CLI over the committed decline store. `record` writes one file per
 * decline under `.gaia/codify-declines/` in the checked-out tree, so the
 * decline reaches teammates through the pull request that carries it. `list`
 * prints the committed files and the legacy per-clone ledger side by side,
 * and `lapsed` names the committed files past the tally window, which a
 * codify pull request may delete. The `snapshot` verbs dispatch to
 * `snapshot.ts`.
 *
 * Suppression itself is decided in `decline-suppression.ts`; this file never
 * judges whether a class is suppressed. The legacy ledger is read for `list`
 * only and is never written.
 */
import {EXIT_CODES} from '../exit.js';
import {readDeclineLedger} from '../schemas/decline-ledger.js';
import {structuredError} from '../stderr.js';
import {
  governingDeclines,
  isLapsed,
  lapsedDeclinePaths,
  readDeclineStore,
  writeDeclineFile,
} from './decline-store.js';
import {runSnapshot} from './snapshot.js';
import {resolveCodifyRoot} from './state-dir.js';
import {WINDOW_DAYS} from './window.js';

const HELP_TEXT = `Usage: gaia codify-ledger <subcommand> [args]

  list
    Print the committed declines and the legacy per-clone ledger as one JSON
    line ({"committed":[],"legacy":[],"skipped":[],"legacy_error":null} when
    both are absent).

  record --finding-class <c> --pr-count <n> --audited-pr-count <d>
    Write one decline file under .gaia/codify-declines/ in the checked-out
    tree and print its repo-relative path. Stamps the file with the live
    TALLY_SCHEMA_VERSION.

  lapsed
    Print the repo-relative path of each committed decline older than the
    tally window, one per line.

  snapshot record [args]
    Dispatches to the review-snapshot verb. See
    \`gaia codify-ledger snapshot --help\`.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

// A parsed-args result is always an object (never a bare string), so a
// consuming function's return type never mixes an object shape with a
// primitive shape.
type ParseResult<T> = {error: string} | {value: T};

type RunOptions = {
  cwd?: string;
  now?: () => Date;
  randomSuffix?: () => string;
};

const parseCountFlag = (value: string | undefined): number | undefined => {
  if (value === undefined) return undefined;
  const parsed = Number.parseInt(value, 10);

  if (!Number.isInteger(parsed) || parsed < 0) return undefined;

  return parsed;
};

const resolveRoot = (
  options: RunOptions,
  subcommand: string
): null | string => {
  try {
    return resolveCodifyRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: `gaia codify-ledger ${subcommand} must run inside a git repository`,
      subcommand: `codify-ledger ${subcommand}`,
    });

    return null;
  }
};

const currentTime = (options: RunOptions): Date =>
  (options.now ?? (() => new Date()))();

const rejectArguments = (
  argv: readonly string[],
  subcommand: string
): boolean => {
  if (argv.length === 0) return false;

  structuredError({
    code: 'invalid_arguments',
    message: `unknown argument: ${argv[0]}`,
    subcommand: `codify-ledger ${subcommand}`,
  });

  return true;
};

// --- list ----------------------------------------------------------------

const handleList = (argv: readonly string[], options: RunOptions): number => {
  if (rejectArguments(argv, 'list')) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  const repoRoot = resolveRoot(options, 'list');

  if (repoRoot === null) return EXIT_CODES.STORAGE_INACCESSIBLE;

  const now = currentTime(options);
  const store = readDeclineStore(repoRoot);
  const governing = new Set(
    Array.from(
      governingDeclines(store.files, now).values(),
      (file) => file.relativePath
    )
  );
  const legacyResult = readDeclineLedger(repoRoot);
  const legacyEntries =
    legacyResult.status === 'ok' ? legacyResult.ledger.declines : [];

  const output = {
    committed: store.files.map(({entry, relativePath}) => ({
      declined_at: entry.declined_at,
      declined_at_audited_pr_count: entry.declined_at_audited_pr_count,
      declined_at_pr_count: entry.declined_at_pr_count,
      finding_class: entry.finding_class,
      governing: governing.has(relativePath),
      lapsed: isLapsed(entry.declined_at, now, WINDOW_DAYS),
      path: relativePath,
      tally_schema_version: entry.tally_schema_version,
    })),
    legacy: legacyEntries.map((entry) => ({
      ...entry,
      lapsed: isLapsed(entry.declined_at, now, WINDOW_DAYS),
    })),
    legacy_error:
      legacyResult.status === 'malformed' ? legacyResult.error : null,
    skipped: store.skipped.map(({reason, relativePath}) => ({
      path: relativePath,
      reason,
    })),
  };

  process.stdout.write(`${JSON.stringify(output)}\n`);

  return EXIT_CODES.OK;
};

// --- record --------------------------------------------------------------

type RecordArgs = {
  auditedPrCount: number | undefined;
  findingClass: string | undefined;
  prCount: number | undefined;
};

const parseRecordArgs = (argv: readonly string[]): ParseResult<RecordArgs> => {
  let findingClass: string | undefined;
  let prCount: number | undefined;
  let auditedPrCount: number | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--finding-class') {
      findingClass = argv[index + 1];
      index += 1;
    } else if (token === '--pr-count') {
      prCount = parseCountFlag(argv[index + 1]);
      index += 1;
    } else if (token === '--audited-pr-count') {
      auditedPrCount = parseCountFlag(argv[index + 1]);
      index += 1;
    } else {
      return {error: `unknown argument: ${token}`};
    }
  }

  return {value: {auditedPrCount, findingClass, prCount}};
};

const handleRecord = (argv: readonly string[], options: RunOptions): number => {
  const parsed = parseRecordArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'codify-ledger record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {auditedPrCount, findingClass, prCount} = parsed.value;

  if (findingClass === undefined || findingClass === '') {
    structuredError({
      code: 'invalid_arguments',
      message: 'codify-ledger record requires --finding-class <c>',
      subcommand: 'codify-ledger record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (prCount === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message:
        'codify-ledger record requires --pr-count <n> (non-negative integer)',
      subcommand: 'codify-ledger record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (auditedPrCount === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message:
        'codify-ledger record requires --audited-pr-count <d> (non-negative integer)',
      subcommand: 'codify-ledger record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const repoRoot = resolveRoot(options, 'record');

  if (repoRoot === null) return EXIT_CODES.STORAGE_INACCESSIBLE;

  try {
    const {relativePath} = writeDeclineFile({
      auditedPrCount,
      findingClass,
      now: currentTime(options),
      prCount,
      randomSuffix: options.randomSuffix,
      repoRoot,
    });

    process.stdout.write(`${relativePath}\n`);
  } catch (error) {
    structuredError({
      code: 'decline_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'codify-ledger record',
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }

  return EXIT_CODES.OK;
};

// --- lapsed --------------------------------------------------------------

const handleLapsed = (argv: readonly string[], options: RunOptions): number => {
  if (rejectArguments(argv, 'lapsed')) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  const repoRoot = resolveRoot(options, 'lapsed');

  if (repoRoot === null) return EXIT_CODES.STORAGE_INACCESSIBLE;

  const paths = lapsedDeclinePaths({
    now: currentTime(options),
    repoRoot,
    windowDays: WINDOW_DAYS,
  });

  for (const lapsedPath of paths) process.stdout.write(`${lapsedPath}\n`);

  return EXIT_CODES.OK;
};

// --- dispatch --------------------------------------------------------------

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [sub, ...rest] = argv;

  if (sub === undefined || HELP_TOKENS.has(sub)) {
    process.stdout.write(HELP_TEXT);

    return sub === undefined ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  if (sub === 'list') return handleList(rest, options);
  if (sub === 'record') return handleRecord(rest, options);
  if (sub === 'lapsed') return handleLapsed(rest, options);
  if (sub === 'snapshot') return runSnapshot(rest, options);

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown codify-ledger subcommand: ${sub}`,
    subcommand: 'codify-ledger',
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
