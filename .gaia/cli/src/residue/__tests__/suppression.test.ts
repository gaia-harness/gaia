import {describe, expect, test} from 'vitest';
import type {IssueRecord} from '../corpus.js';
import {evaluateIssueArms} from '../suppression.js';

const wrappedKey = (path: string, line: number): string =>
  `<!-- gaia-debt-key: v1 class=holistic/unclassified path=${path} line=${line} -->`;

const issue = (overrides: Partial<IssueRecord>): IssueRecord => ({
  body: '',
  labels: [],
  number: 1,
  state: 'OPEN',
  stateReason: null,
  ...overrides,
});

describe('evaluateIssueArms', () => {
  const notSuppressed = {previously_promoted_issue: null, suppressed: false};
  const suppressed = {suppressed: true};

  test.each<{
    checks: {expected: object; line: number}[];
    issues: IssueRecord[];
    title: string;
  }>([
    {
      checks: [{expected: suppressed, line: 10}],
      issues: [
        issue({
          body: '<!-- gaia-debt-key: v1 class=different/class path=app/x.ts line=10 -->',
          number: 5,
          state: 'OPEN',
        }),
      ],
      title:
        'arm 1: an open issue whose key matches on path and line suppresses, regardless of class',
    },
    {
      checks: [{expected: notSuppressed, line: 11}],
      issues: [issue({body: wrappedKey('app/x.ts', 10), state: 'OPEN'})],
      title:
        'arm 1: a second residual on the same path at a different line is not suppressed',
    },
    {
      checks: [{expected: suppressed, line: 10}],
      issues: [
        issue({
          body: wrappedKey('app/x.ts', 10),
          labels: [{name: 'wontfix'}],
          state: 'CLOSED',
          stateReason: null,
        }),
      ],
      title: 'arm 2: a declined-closed issue carrying wontfix suppresses',
    },
    {
      checks: [{expected: suppressed, line: 10}],
      issues: [
        issue({
          body: wrappedKey('app/x.ts', 10),
          state: 'CLOSED',
          stateReason: 'NOT_PLANNED',
        }),
      ],
      title:
        'arm 2: a closed issue with stateReason NOT_PLANNED and no wontfix label suppresses too',
    },
    {
      checks: [
        {expected: suppressed, line: 4},
        {expected: notSuppressed, line: 42},
      ],
      issues: [issue({body: 'see app/x.ts:4 for detail', state: 'OPEN'})],
      title:
        'arm 3: a keyless bare path:line mention in an open issue suppresses, anchored against a sibling line',
    },
    {
      checks: [{expected: notSuppressed, line: 4}],
      issues: [issue({body: 'see app/x.ts:4 for detail', state: 'CLOSED'})],
      title: 'arm 3: the same bare mention in a closed issue does not suppress',
    },
  ])('$title', ({checks, issues}) => {
    for (const {expected, line} of checks) {
      expect(evaluateIssueArms(issues, {line, path: 'app/x.ts'})).toEqual(
        expected
      );
    }
  });

  test('a spaced-path key and a no-v1 key are each read by parseWrappedKeys and each suppress, the no-v1 leniency surviving after the path terminator moved', () => {
    const spacedPathIssue = issue({
      body: '<!-- gaia-debt-key: v1 class=x/y path=app/some file.ts line=3 -->',
      state: 'OPEN',
    });

    expect(
      evaluateIssueArms([spacedPathIssue], {line: 3, path: 'app/some file.ts'})
    ).toEqual({suppressed: true});

    const noV1Issue = issue({
      body: '<!-- gaia-debt-key: class=x/y path=app/z.ts line=8 -->',
      state: 'OPEN',
    });

    expect(evaluateIssueArms([noV1Issue], {line: 8, path: 'app/z.ts'})).toEqual(
      {
        suppressed: true,
      }
    );
  });

  test('a closed-as-completed issue (no wontfix, no NOT_PLANNED) does not suppress and flags previously_promoted_issue', () => {
    const issues = [
      issue({
        body: wrappedKey('app/x.ts', 10),
        number: 77,
        state: 'CLOSED',
        stateReason: null,
      }),
    ];

    expect(evaluateIssueArms(issues, {line: 10, path: 'app/x.ts'})).toEqual({
      previously_promoted_issue: 77,
      suppressed: false,
    });
  });
});
