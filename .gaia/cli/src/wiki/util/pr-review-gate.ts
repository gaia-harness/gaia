import {z} from 'zod';
import type {CommandRunner} from './branch.js';
import {commandSucceeded} from './land.js';

// A spawn failure can leave stdout/stderr null at runtime despite their type.
const safeOutput = (value: null | string | undefined): string => value ?? '';

const OpenPullRequestSchema = z.object({
  number: z.number().int().positive(),
  state: z.string(),
  url: z.string(),
});

export type OpenPullRequest = {number: number; url: string};

export type PullRequestReviewCheck =
  {isComplete: true} | {isUnavailable: boolean; line: string};

type PullRequestReviewOptions = {
  cwd: string;
  prNumber: number;
  runner: CommandRunner;
};

/** The branch's open pull request, or `undefined` when gh finds none. */
export const findOpenPullRequest = (
  options: Omit<PullRequestReviewOptions, 'prNumber'> & {branch: string}
): OpenPullRequest | undefined => {
  const {branch, cwd, runner} = options;
  const result = runner(
    'gh',
    ['pr', 'view', branch, '--json', 'number,url,state'],
    {cwd}
  );

  if (!commandSucceeded(result)) return undefined;

  let parsed: unknown;

  try {
    parsed = JSON.parse(safeOutput(result.stdout));
  } catch {
    return undefined;
  }

  const record = OpenPullRequestSchema.safeParse(parsed);

  if (!record.success || record.data.state !== 'OPEN') return undefined;

  return {number: record.data.number, url: record.data.url};
};

/**
 * Run the PR review gate script for the pull request and return a pass or the
 * script's own `PR review: <reason>.` line, so the verdict stays defined once.
 * A script that could not answer is a failure line, never a pass.
 */
export const checkPullRequestReview = (
  options: PullRequestReviewOptions
): PullRequestReviewCheck => {
  const {cwd, prNumber, runner} = options;
  const result = runner(
    'bash',
    [
      '.gaia/scripts/pr-review-gate.sh',
      'check',
      '--root',
      cwd,
      '--pr',
      String(prNumber),
      '--out-of-scope',
    ],
    {cwd}
  );

  if (commandSucceeded(result)) return {isComplete: true};

  const line = safeOutput(result.stdout).trim();

  if (result.status === 1 && line !== '') return {isUnavailable: false, line};

  const detail = safeOutput(result.stderr).trim() || 'the gate could not run';

  return {
    isUnavailable: true,
    line: `PR review: could not be checked on PR #${prNumber} (${detail}).`,
  };
};
