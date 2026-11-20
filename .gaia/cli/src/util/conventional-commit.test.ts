import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import {
  COMMIT_TYPES,
  isCommitType,
  parseConventionalCommitHeader,
} from './conventional-commit.js';

const header = (
  type: string,
  scope: string | undefined,
  rest: string,
  breaking = false
) => ({breaking, rest, scope, type});

const NOT_A_HEADER = [
  'Harden the Code Audit Team merge gate (#793)',
  'Merge pull request #42 from feature/foo',
  'FIX: shouting is not the grammar',
  'fix2: digits are not part of the type',
  'fix (hooks): a space before the scope breaks it',
  '',
];

describe('parseConventionalCommitHeader', () => {
  // Read by `bump.ts`, `changelog.ts` and `commit-classify.ts`.
  test.each(
    [
      {
        expected: header('fix', undefined, 'repair the thing'),
        name: 'parses a bare type',
        subject: 'fix: repair the thing',
      },
      {
        expected: header('fix', 'hooks', 'repair the thing'),
        name: 'captures the scope by name',
        subject: 'fix(hooks): repair the thing',
      },
      {
        expected: header('feat', undefined, 'drop it', true),
        name: 'feat!: drop it exposes scope and bang together',
        subject: 'feat!: drop it',
      },
      {
        expected: header('chore', 'cli', 'drop it', true),
        name: 'chore(cli)!: drop it exposes scope and bang together',
        subject: 'chore(cli)!: drop it',
      },
      {
        expected: header('refactor', 'a/b', 'move it', true),
        name: 'refactor(a/b)!: move it exposes scope and bang together',
        subject: 'refactor(a/b)!: move it',
      },
      {
        expected: header('fix', '', 'thing'),
        name: 'an empty scope is captured as an empty string, not undefined',
        subject: 'fix(): thing',
      },
      {
        expected: header('feat', 'api', 'spaced'),
        name: 'rest is the message with surrounding whitespace stripped',
        subject: 'feat(api):   spaced   ',
      },
      {
        expected: header('chore', undefined, ''),
        name: 'rest is empty when the subject is only a header',
        subject: 'chore:',
      },
      {
        expected: header('fix', undefined, 'thing'),
        name: 'leading whitespace on the subject does not defeat the match',
        subject: '  fix: thing',
      },
      ...NOT_A_HEADER.map((subject) => ({
        expected: undefined,
        name: `${subject} is not a conventional-commit header`,
        subject,
      })),
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {expected, subject}) => {
    expect(parseConventionalCommitHeader(subject)).toEqual(expected);
  });
});

describe('COMMIT_TYPES', () => {
  // Only the negative case is worth asserting. That `isCommitType` accepts
  // every member of the list it is built from restates the implementation, and
  // freezing the list here would catch nothing: each consumer's
  // `Record<CommitType, ...>` already fails to compile on both an added type
  // (missing key) and a removed one (excess key).
  test('isCommitType rejects a type nobody declared', () => {
    expect(isCommitType('spike')).toBe(false);
  });
});

type SharedTypeFile = {legacyTypes: string[]; types: string[]};

/**
 * Throw unless the CLI's literal tuple names exactly the shared file's `types`
 * plus `legacyTypes`.
 */
const assertTypesAgree = (
  cliTypes: readonly string[],
  shared: SharedTypeFile
): void => {
  const expected = [...shared.types, ...shared.legacyTypes];
  const expectedSet = new Set(expected);
  const agrees =
    cliTypes.length === expected.length &&
    cliTypes.every((type) => expectedSet.has(type));

  if (!agrees) {
    throw new Error(
      `COMMIT_TYPES [${cliTypes.join(', ')}] disagrees with .gaia/conventional-commits.json [${expected.join(', ')}]`
    );
  }
};

describe('COMMIT_TYPES lockstep with .gaia/conventional-commits.json', () => {
  const shared = JSON.parse(
    readFileSync(
      new URL('../../../conventional-commits.json', import.meta.url),
      'utf8'
    )
  ) as SharedTypeFile;

  test('the tuple equals types plus legacyTypes', () => {
    expect(() => assertTypesAgree(COMMIT_TYPES, shared)).not.toThrow();
  });

  test('debt stays parseable but is not a type for new commits', () => {
    expect(isCommitType('debt')).toBe(true);
    expect(shared.types).not.toContain('debt');
  });
});
