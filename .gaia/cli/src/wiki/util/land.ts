import {z} from 'zod';
/**
 * Shared landing primitives for the wiki `chain` command.
 *
 * They shell out through an injected `CommandRunner` and translate git/gh
 * outcomes into the CLI's exit-code contract: 0 (ok) / 1 (refusal) /
 * 2 (unexpected).
 */
import type {SpawnSyncReturns} from 'node:child_process';
import {EXIT_CODES} from '../../exit.js';
import type {CommandRunner} from './branch.js';

/** Exit code for an unexpected git/gh process failure. */
export const UNEXPECTED_EXIT = 2;

/** UTC `YYYY-MM-DD`; the date component of a `wiki/sync-<date>-<sha>` branch. */
export const todayUtc = (now: Date = new Date()): string => {
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, '0');
  const day = String(now.getUTCDate()).padStart(2, '0');

  return `${year}-${month}-${day}`;
};

/** Print a user-correctable refusal to stderr and return exit code 1. */
export const refuse = (message: string): number => {
  process.stderr.write(`${message}\n`);

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

/** A git/gh step succeeded: no spawn error and a zero exit status. */
export const commandSucceeded = (result: SpawnSyncReturns<string>): boolean =>
  result.error === undefined && (result.status ?? -1) === 0;

// `SpawnSyncReturns.stdout`/`.stderr` are typed as non-nullable `string`, but
// a spawn failure can genuinely leave them `null`/`undefined` at runtime
// despite the type declaration.
const safeOutput = (value: null | string | undefined): string => value ?? '';

export type PassthroughFailureOptions = {
  args: readonly string[];
  command: string;
  prefix: string;
  result: SpawnSyncReturns<string>;
};

/**
 * Surface a failing git/gh step (command + argv + its stderr) under `prefix`
 * and return exit code 2. The caller gets enough context to diagnose without
 * re-running; the CLI adds nothing beyond that.
 */
export const passthroughFailure = (
  options: PassthroughFailureOptions
): number => {
  const {args, command, prefix, result} = options;
  const stderr = safeOutput(result.stderr).trim();
  const errorPart =
    result.error === undefined ? '' : ` (${result.error.message})`;
  const status = result.status ?? -1;
  process.stderr.write(
    `${prefix}: ${command} ${args.join(' ')} exited ${status}${errorPart}\n`
  );

  if (stderr.length > 0) process.stderr.write(`${stderr}\n`);

  return UNEXPECTED_EXIT;
};

export type OutOfScopeStampOptions = {
  branch: string;
  cwd: string;
  prefix: string;
  runner: CommandRunner;
};

/** Whether the landing PR is ready for review after the stamp step. */
export type OutOfScopeStampResult = 'flip-failed' | 'not-posted' | 'ready';

const OUT_OF_SCOPE_DESCRIPTION = 'skipped: out of scope';

const PullRequestRecordSchema = z.object({
  baseRefName: z.string().min(1),
  files: z.array(z.object({path: z.string()})),
  headRefOid: z.string().min(1),
});

type PullRequestRecordResult =
  {reason: string} | {record: z.infer<typeof PullRequestRecordSchema>};

const failureDetail = (result: SpawnSyncReturns<string>): string => {
  const stderr = safeOutput(result.stderr).trim();

  return stderr === '' ? `exit ${result.status ?? -1}` : stderr;
};

const readPullRequestRecord = (
  options: OutOfScopeStampOptions
): PullRequestRecordResult => {
  const {branch, cwd, runner} = options;
  const view = runner(
    'gh',
    ['pr', 'view', branch, '--json', 'files,headRefOid,baseRefName'],
    {cwd}
  );

  if (!commandSucceeded(view)) {
    return {reason: `could not read the pull request (${failureDetail(view)})`};
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(safeOutput(view.stdout));
  } catch {
    return {reason: 'the pull request record is not JSON'};
  }

  const record = PullRequestRecordSchema.safeParse(parsed);

  return record.success ?
      {record: record.data}
    : {reason: 'the pull request record is malformed'};
};

/**
 * Post the `GAIA-Audit` out-of-scope success status on the landing branch's
 * head, for the wiki-only PR the CLI merges itself with auto-merge, outside the
 * Claude Code merge hook that stamps every other bypass PR, then mark a draft
 * PR ready for review (a PR opened ready is left as is). Call it after
 * `gh pr create` and before the auto-merge step.
 *
 * The subject is the pull request, not the local checkout: both landers cut
 * their branch from a local default branch that can carry commits origin never
 * received, and a diff against it would hide those commits from the roster
 * while the PR still contains them. So the changed set is the PR's own file
 * list, its recorded head must be the commit this checkout holds, and the
 * roster is resolved against the PR base fetched from the remote.
 *
 * Refuses (one stderr line, no POST) unless every PR path is under `wiki/`, the
 * recorded head equals local `HEAD`, and the Code Audit Team roster dispatches
 * no member for the diff. The roster check keeps a later roster entry that owns
 * a `wiki/` path from letting the path check alone clear an in-scope PR. Any
 * failure to answer refuses too, since "could not answer" is not "nobody is
 * owed".
 *
 * The ready flip runs strictly after the status POST, so a reviewer is notified
 * only once the status exists. The result tells the caller whether the pull
 * request is now ready: `not-posted` leaves it a draft for the PR Merge
 * Workflow to flip, and `flip-failed` leaves a posted status on a still-draft
 * PR. Each prints its own next step, and the status is never rolled back.
 */
export const postOutOfScopeStamp = (
  options: OutOfScopeStampOptions
): OutOfScopeStampResult => {
  const {branch, cwd, prefix, runner} = options;

  const refusePost = (reason: string): OutOfScopeStampResult => {
    process.stderr.write(
      `${prefix}: GAIA-Audit out-of-scope stamp not posted: ${reason}; run the PR Merge Workflow on this pull request\n`
    );

    return 'not-posted';
  };

  const read = readPullRequestRecord(options);

  if ('reason' in read) {
    return refusePost(read.reason);
  }

  const {record} = read;

  const head = runner('git', ['rev-parse', 'HEAD'], {cwd});
  const headSha = commandSucceeded(head) ? safeOutput(head.stdout).trim() : '';

  if (headSha === '') {
    return refusePost('could not resolve the head commit');
  }

  if (record.headRefOid !== headSha) {
    return refusePost(
      'the pull request head is not the commit this checkout holds'
    );
  }

  if (
    record.files.length === 0 ||
    record.files.some((file) => !file.path.startsWith('wiki/'))
  ) {
    return refusePost('the pull request changes paths outside wiki/');
  }

  // A base name that starts with `-` would be read as an option by `git fetch`.
  if (record.baseRefName.startsWith('-')) {
    return refusePost('the pull request base name is not a branch name');
  }

  const fetchBase = runner('git', ['fetch', 'origin', record.baseRefName], {
    cwd,
  });

  if (!commandSucceeded(fetchBase)) {
    return refusePost(
      `could not fetch origin/${record.baseRefName} (${failureDetail(fetchBase)})`
    );
  }

  const members = runner(
    'bash',
    [
      '.gaia/scripts/resolve-audit-members.sh',
      '--root',
      cwd,
      '--base',
      `origin/${record.baseRefName}`,
    ],
    {cwd}
  );

  if (!commandSucceeded(members)) {
    return refusePost(
      `resolve-audit-members.sh could not answer (${failureDetail(members)})`
    );
  }

  const dispatched = safeOutput(members.stdout)
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  if (dispatched.length > 0) {
    return refusePost(
      `the Code Audit Team dispatches ${dispatched.join(', ')} for this diff`
    );
  }

  const post = runner(
    'gh',
    [
      'api',
      '-X',
      'POST',
      `repos/{owner}/{repo}/statuses/${headSha}`,
      '-f',
      'state=success',
      '-f',
      'context=GAIA-Audit',
      '-f',
      `description=${OUT_OF_SCOPE_DESCRIPTION}`,
    ],
    {cwd}
  );

  if (!commandSucceeded(post)) {
    return refusePost(`the status POST failed (${failureDetail(post)})`);
  }

  // A pull request opened ready (a private repository that refuses drafts) has
  // nothing to flip; an unreadable draft state falls through to the flip.
  const draftState = runner(
    'gh',
    ['pr', 'view', branch, '--json', 'isDraft', '--jq', '.isDraft'],
    {cwd}
  );

  if (
    commandSucceeded(draftState) &&
    safeOutput(draftState.stdout).trim() === 'false'
  ) {
    return 'ready';
  }

  const ready = runner('gh', ['pr', 'ready', branch], {cwd});

  if (!commandSucceeded(ready)) {
    process.stderr.write(
      `${prefix}: GAIA-Audit status posted but the draft flip failed (${failureDetail(ready)}); run: gh pr ready ${branch}\n`
    );

    return 'flip-failed';
  }

  return 'ready';
};
