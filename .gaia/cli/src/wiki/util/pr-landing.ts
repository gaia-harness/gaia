import type {SpawnSyncReturns} from 'node:child_process';
import {EXIT_CODES} from '../../exit.js';
import type {CommandRunner} from './branch.js';
import {
  passthroughFailure as passthroughFailureWithPrefix,
  postOutOfScopeStamp,
  commandSucceeded as stepOk,
} from './land.js';
import {checkPullRequestReview, findOpenPullRequest} from './pr-review-gate.js';

/** A pull request `gh pr create` printed, parsed from its URL. */
type GhArtifact = {number: number; repo: string};

// `SpawnSyncReturns.stdout` is typed as non-nullable `string`, but a spawn
// failure can genuinely leave it `null`/`undefined` at runtime despite the
// type declaration.
const safeOutput = (value: null | string | undefined): string => value ?? '';

const PR_URL = /https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/(\d+)/u;

/**
 * Parse the first anchored `.../pull/<n>` URL out of `gh pr create`'s stdout.
 * A non-URL line, an `/issues/` URL, or an owner/repo outside the safe
 * character class all return `undefined` rather than a partial artifact.
 */
const parsePrUrl = (text: string): GhArtifact | undefined => {
  const match = PR_URL.exec(text);

  if (match === null) return undefined;

  const repo = match[1];
  const numberToken = match[2];

  if (repo === undefined || numberToken === undefined) return undefined;

  const number = Number.parseInt(numberToken, 10);

  if (!Number.isSafeInteger(number) || number <= 0) return undefined;

  return {number, repo};
};

const DRAFT_UNSUPPORTED =
  /draft.*(?:not supported|unsupported)|(?:not supported|unsupported).*draft/i;

type OpenPullRequestOptions = {
  prBody: string;
  prTitle: string;
  repoRoot: string;
  runner: CommandRunner;
};

type OpenPullRequestResult = {args: string[]; result: SpawnSyncReturns<string>};

/**
 * Open the PR as a draft, or ready where GitHub refuses drafts. An exact
 * PRIVATE visibility answer opens it ready (some plans refuse drafts there);
 * a draft create refused for unsupported drafts is retried once as ready.
 */
const openPullRequest = (
  options: OpenPullRequestOptions
): OpenPullRequestResult => {
  const {prBody, prTitle, repoRoot, runner} = options;
  const createArgs = (draft: boolean): string[] => [
    'pr',
    'create',
    ...(draft ? ['--draft'] : []),
    '--title',
    prTitle,
    '--body',
    prBody,
  ];
  const visibility = runner(
    'gh',
    ['repo', 'view', '--json', 'visibility', '--jq', '.visibility'],
    {cwd: repoRoot}
  );
  const isPrivate =
    stepOk(visibility) && safeOutput(visibility.stdout).trim() === 'PRIVATE';
  const args = createArgs(!isPrivate);
  const result = runner('gh', args, {cwd: repoRoot});

  if (
    stepOk(result) ||
    isPrivate ||
    !DRAFT_UNSUPPORTED.test(safeOutput(result.stderr))
  ) {
    return {args, result};
  }

  const readyArgs = createArgs(false);

  return {args: readyArgs, result: runner('gh', readyArgs, {cwd: repoRoot})};
};

export type QueueAutoMergeResult = {
  artifact?: GhArtifact;
  failureCode?: number;
};

type QueueAutoMergeOptions = {
  branch: string;
  prBody: string;
  prTitle: string;
  repoRoot: string;
  runner: CommandRunner;
};

/**
 * Push the wiki branch, open its PR as a draft (ready on a private repository
 * that refuses drafts) or reuse the one already open for it, require a complete
 * PR review, post the out-of-scope stamp, mark the PR ready, and queue
 * auto-merge. Runs while still on the wiki branch so `gh pr merge` targets its
 * PR; once `push` succeeds the branch exists on the remote and is left for the
 * maintainer to resolve rather than force-reverted.
 *
 * An absent or incomplete review stops the land before the stamp and the merge
 * with the PR left open: the caller runs the review and finishes again, and the
 * second run reuses the open PR. A flip that failed stops the land before the
 * merge step with the PR still an open draft; a stamp that did not post goes on
 * to the merge step, where GitHub refuses auto-merge on the draft after the
 * refusal line has named the next step.
 */
export const queueAutoMerge = (
  options: QueueAutoMergeOptions
): QueueAutoMergeResult => {
  const {branch, prBody, prTitle, repoRoot, runner} = options;
  const failure = (
    result: SpawnSyncReturns<string>,
    command: string,
    args: readonly string[]
  ): QueueAutoMergeResult => ({
    failureCode: passthroughFailureWithPrefix({
      args,
      command,
      prefix: 'chain',
      result,
    }),
  });

  const pushArgs = ['push', '-u', 'origin', branch];
  const push = runner('git', pushArgs, {cwd: repoRoot});

  if (!stepOk(push)) return failure(push, 'git', pushArgs);

  const openPullRequestRecord = findOpenPullRequest({
    branch,
    cwd: repoRoot,
    runner,
  });
  let artifact: GhArtifact | undefined;

  if (openPullRequestRecord === undefined) {
    const created = openPullRequest({prBody, prTitle, repoRoot, runner});

    if (!stepOk(created.result)) {
      return failure(created.result, 'gh', created.args);
    }

    artifact = parsePrUrl(safeOutput(created.result.stdout));
  } else {
    artifact = parsePrUrl(openPullRequestRecord.url);
  }

  if (artifact === undefined) {
    process.stderr.write(
      `chain finish: could not read the pull request number for ${branch}; no review check, stamp or auto-merge ran\n`
    );

    return {failureCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  const review = checkPullRequestReview({
    cwd: repoRoot,
    prNumber: artifact.number,
    runner,
  });

  if ('line' in review) {
    process.stderr.write(`${review.line}\n`);

    return {failureCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  // `--auto` merges outside the Claude Code merge hook, so nothing else posts
  // GAIA-Audit for a wiki-only PR on a branch that requires it. The poster
  // refuses a diff that leaves `wiki/` or that the roster dispatches.
  const stamp = postOutOfScopeStamp({
    branch,
    cwd: repoRoot,
    prefix: 'chain finish',
    runner,
  });

  if (stamp === 'flip-failed') {
    process.stderr.write(
      `chain finish: ${branch} stays an open draft PR and auto-merge is not queued\n`
    );

    return {failureCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  const mergeArgs = ['pr', 'merge', '--squash', '--auto', '--delete-branch'];
  const merge = runner('gh', mergeArgs, {cwd: repoRoot});

  if (!stepOk(merge)) return failure(merge, 'gh', mergeArgs);

  return {artifact};
};
