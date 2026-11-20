/**
 * Unit tests for the pure answer machinery behind the `release manifest`
 * refusal gate.
 *
 * Every case runs against the inline fixture below, never against the live
 * `.gaia/release-exclude`. The real boundary file is edited whenever a
 * maintainer withholds something, so a test asserting "category 1's last line
 * is X" or "the file has twelve categories" would be a test of today's
 * distribution boundary rather than of this module.
 */
import {describe, expect, test} from 'vitest';
import {
  applyWithholds,
  parseExcludeCategories,
  validateAnswers,
} from './manifest-answers.js';
import type {
  AnswerErrorCode,
  AnswerSet,
  WithholdAnswer,
} from './manifest-answers.js';

const EXCLUDE_FIXTURE = [
  '# Paths excluded from the distribution tarball.',
  '# One path or glob per line; `#` comments are honored.',
  '',
  '# --- 1. Maintainer-only Claude surface ---',
  '# Commands only the maintainer ever runs.',
  '.claude/commands/gaia-release.md',
  '.gaia/statusline/preferred-base.sh',
  '',
  '# --- 2. Maintainer-only wiki content ---',
  '# Internal vault administration.',
  'wiki/entities',
  '',
  '# --- 3. Test harnesses and audit reports ---',
  '.gaia/tests',
  '',
].join('\n');

const withhold = (
  path: string,
  overrides: Partial<WithholdAnswer> = {}
): WithholdAnswer => ({
  category: 1,
  path,
  reason: 'maintainer-only',
  ...overrides,
});

const answers = (overrides: Partial<AnswerSet> = {}): AnswerSet => ({
  allowUndecided: false,
  ships: [],
  withdraws: [],
  withholds: [],
  ...overrides,
});

const codesOf = (
  errors: readonly {code: AnswerErrorCode}[]
): AnswerErrorCode[] => errors.map((error) => error.code);

const CATEGORIES = parseExcludeCategories(EXCLUDE_FIXTURE);

describe('parseExcludeCategories', () => {
  test.each<{expected: unknown[]; name: string; text: string}>([
    {
      expected: [
        {
          headerLineIndex: 3,
          number: 1,
          title: 'Maintainer-only Claude surface',
        },
        {headerLineIndex: 8, number: 2, title: 'Maintainer-only wiki content'},
        {
          headerLineIndex: 12,
          number: 3,
          title: 'Test harnesses and audit reports',
        },
      ],
      name: 'finds every numbered header in file order with 0-based line indices',
      text: EXCLUDE_FIXTURE,
    },
    {
      expected: [],
      name: 'ignores comments and path lines that are not numbered headers',
      text: '# just a comment\nwiki/entities\n',
    },
    {
      expected: [],
      name: 'returns an empty list for an empty body',
      text: '',
    },
  ])('$name', ({expected, text}) => {
    expect(parseExcludeCategories(text)).toEqual(expected);
  });
});

describe('applyWithholds', () => {
  test('inserts the reason comment and the verbatim path at column zero', () => {
    const result = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('.gaia/statusline/example.sh'),
    ]);
    const lines = result.split('\n');
    const pathIndex = lines.indexOf('.gaia/statusline/example.sh');

    expect(pathIndex).toBeGreaterThan(-1);
    expect(lines[pathIndex - 1]).toBe('# maintainer-only');
  });

  test('inserts below the chosen header and above the next one', () => {
    const lines = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('wiki/meta', {category: 2, reason: 'internal'}),
    ]).split('\n');
    const pathIndex = lines.indexOf('wiki/meta');

    expect(pathIndex).toBeGreaterThan(
      lines.findIndex((line) => line.startsWith('# --- 2.'))
    );
    expect(pathIndex).toBeLessThan(
      lines.findIndex((line) => line.startsWith('# --- 3.'))
    );
  });

  test('inserts after the last non-blank line, keeping the blank separator', () => {
    const lines = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('.gaia/statusline/example.sh'),
    ]).split('\n');
    const pathIndex = lines.indexOf('.gaia/statusline/example.sh');

    // The category's own last path line, then the two new lines, then the
    // blank line that separates the block from the next header.
    expect(lines[pathIndex - 2]).toBe('.gaia/statusline/preferred-base.sh');
    expect(lines[pathIndex + 1]).toBe('');
    expect(lines[pathIndex + 2]).toBe(
      '# --- 2. Maintainer-only wiki content ---'
    );
  });

  test('appends a second withhold into the same category below the first', () => {
    const lines = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('.gaia/statusline/first.sh', {reason: 'first'}),
      withhold('.gaia/statusline/second.sh', {reason: 'second'}),
    ]).split('\n');
    const firstIndex = lines.indexOf('.gaia/statusline/first.sh');
    const secondIndex = lines.indexOf('.gaia/statusline/second.sh');

    expect(firstIndex).toBeGreaterThan(-1);
    expect(secondIndex).toBe(firstIndex + 2);
    expect(lines[secondIndex - 1]).toBe('# second');
    expect(lines[secondIndex + 1]).toBe('');
  });

  test('routes withholds to their own categories', () => {
    const lines = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('.gaia/statusline/example.sh'),
      withhold('wiki/meta', {category: 2, reason: 'internal'}),
      withhold('.gaia/probe', {category: 3, reason: 'harness'}),
    ]).split('\n');
    const header2 = lines.findIndex((line) => line.startsWith('# --- 2.'));
    const header3 = lines.findIndex((line) => line.startsWith('# --- 3.'));

    expect(lines.indexOf('.gaia/statusline/example.sh')).toBeLessThan(header2);
    expect(lines.indexOf('wiki/meta')).toBeGreaterThan(header2);
    expect(lines.indexOf('wiki/meta')).toBeLessThan(header3);
    expect(lines.indexOf('.gaia/probe')).toBeGreaterThan(header3);
  });

  test('appends into the last category, preserving the trailing newline', () => {
    const result = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('.gaia/probe', {category: 3, reason: 'harness'}),
    ]);

    expect(result.endsWith('# harness\n.gaia/probe\n')).toBe(true);
  });

  test('leaves the text untouched when there is nothing to withhold', () => {
    expect(applyWithholds(EXCLUDE_FIXTURE, [])).toBe(EXCLUDE_FIXTURE);
  });
});

type CaseBase = {
  answerSet: AnswerSet;
  name: string;
  report?: {missing: string[]; shipped: string[]};
};
type ContainsCase = CaseBase & {contains: AnswerErrorCode[]};
type ContainsPathsCase = ContainsCase & {
  notContains: AnswerErrorCode[];
  paths: string[];
};
type ExactCase = CaseBase & {codes: AnswerErrorCode[]};
type ExactPathsCase = ExactCase & {paths: string[]};

const FRESH_REPORT = {missing: ['app/new.ts', 'docs/guide.md'], shipped: []};
const WITHDRAW_REPORT = {
  missing: ['app/new.ts'],
  shipped: ['.github/FUNDING.yml', 'app/foo.ts'],
};

const metacharacterCase = (label: string, badPath: string): ContainsCase => ({
  answerSet: answers({allowUndecided: true, withholds: [withhold(badPath)]}),
  contains: ['withhold_metacharacter'],
  name: `withhold_metacharacter rejects ${label}`,
  report: {missing: [badPath], shipped: []},
});

const allowedPathCase = (label: string, goodPath: string): ExactCase => ({
  answerSet: answers({allowUndecided: true, withholds: [withhold(goodPath)]}),
  codes: [],
  name: `allows ${label} in a withhold path`,
  report: {missing: [goodPath], shipped: []},
});

const reasonCase = (label: string, reason: string): ExactCase => ({
  answerSet: answers({
    allowUndecided: true,
    withholds: [withhold('app/new.ts', {reason})],
  }),
  codes: ['withhold_reason_invalid'],
  name: `withhold_reason_invalid rejects ${label}`,
});

describe('validateAnswers', () => {
  test.each<ExactCase>([
    {
      answerSet: answers({
        ships: ['app/new.ts'],
        withholds: [withhold('docs/guide.md')],
      }),
      codes: [],
      name: 'returns no errors for an exactly-covering answer set',
    },
    {
      answerSet: answers({
        allowUndecided: true,
        withholds: [withhold('docs/notes[1].md')],
      }),
      codes: ['withhold_metacharacter'],
      name: 'withhold_metacharacter rejects a bracketed filename that IS a member',
      report: {missing: ['docs/notes[1].md'], shipped: []},
    },
    allowedPathCase('a dot and a plus', 'app/routes/_public+/home.tsx'),
    allowedPathCase('a tilde and an at', 'docs/~notes@2.md'),
    allowedPathCase('a comma and an equals', 'docs/a,b=c.md'),
    // Every wiki/ title carries spaces, and .gaia/release-exclude already
    // holds such lines. An exclude line is a literal path to every consumer,
    // so a space is literal in all of them; refusing to write one would make
    // a whole category of maintainer-only page unwithholdable.
    allowedPathCase(
      'an interior space',
      'wiki/decisions/Sharded CI Test Matrix.md'
    ),
    reasonCase('a newline', 'internal\nwiki/decisions'),
    reasonCase('a carriage return', 'internal\rwiki/decisions'),
    reasonCase('an empty reason', ''),
    reasonCase('a whitespace-only reason', ' '.repeat(3)),
    {
      answerSet: answers({
        ships: ['app/ghost.ts'],
        withholds: [
          withhold('docs/*.md', {category: 99, reason: 'bad\nreason'}),
        ],
      }),
      codes: [
        'answer_not_missing',
        'withhold_metacharacter',
        'withhold_reason_invalid',
        'unknown_category',
        'unanswered_paths',
      ],
      name: 'reports every error class in one pass',
    },
    {
      answerSet: answers({
        allowUndecided: true,
        withholds: [withhold('app/foo.ts')],
      }),
      codes: ['answer_not_missing'],
      name: 'a withhold of an already-shipped path is still answer_not_missing',
      report: WITHDRAW_REPORT,
    },
  ])('$name', ({answerSet, codes, report = FRESH_REPORT}) => {
    expect(codesOf(validateAnswers(answerSet, report, CATEGORIES))).toEqual(
      codes
    );
  });

  test.each<ExactPathsCase>([
    {
      answerSet: answers(),
      codes: ['unanswered_paths'],
      name: 'unanswered_paths names every unanswered file',
      paths: ['app/new.ts', 'docs/guide.md'],
    },
    {
      answerSet: answers({ships: ['app/typo.ts', 'docs/typo.md']}),
      codes: ['answer_not_missing', 'unanswered_paths'],
      name: 'answer_not_missing collects every offending path, not just the first',
      paths: ['app/typo.ts', 'docs/typo.md'],
    },
    {
      answerSet: answers({
        allowUndecided: true,
        withholds: [withhold('app/new.ts', {category: 99})],
      }),
      codes: ['unknown_category'],
      name: 'unknown_category rejects a category no header declares',
      paths: ['app/new.ts'],
    },
    {
      answerSet: answers({
        allowUndecided: true,
        withdraws: [withhold('app/ghost.ts'), withhold('app/new.ts')],
      }),
      codes: ['withdraw_not_shipped'],
      name: 'withdraw_not_shipped rejects a path the manifest does not ship, a newly-shipping one included',
      paths: ['app/ghost.ts', 'app/new.ts'],
      report: WITHDRAW_REPORT,
    },
  ])('$name', ({answerSet, codes, paths, report = FRESH_REPORT}) => {
    const errors = validateAnswers(answerSet, report, CATEGORIES);

    expect(codesOf(errors)).toEqual(codes);
    expect(errors[0]?.paths).toEqual(paths);
  });

  test.each<ContainsPathsCase>([
    {
      // The directory carries no metacharacter; membership is what rejects it.
      answerSet: answers({
        ships: ['app/new.ts'],
        withholds: [withhold('docs', {reason: 'internal'})],
      }),
      contains: ['answer_not_missing'],
      name: 'answer_not_missing rejects a bare directory standing in for its subtree',
      notContains: ['withhold_metacharacter'],
      paths: ['docs'],
    },
  ])(
    '$name',
    ({answerSet, contains, notContains, paths, report = FRESH_REPORT}) => {
      const errors = validateAnswers(answerSet, report, CATEGORIES);

      for (const code of contains) {
        expect(codesOf(errors)).toContain(code);
      }

      for (const code of notContains) {
        expect(codesOf(errors)).not.toContain(code);
      }

      expect(errors[0]?.paths).toEqual(paths);
    }
  );

  test.each<ContainsCase>([
    metacharacterCase('a star', 'docs/*.md'),
    metacharacterCase('a brace', 'docs/{a,b}.md'),
    metacharacterCase('an anchor', '^docs/a.md'),
    metacharacterCase('a pipe', 'docs/a|b.md'),
    metacharacterCase('a backslash', String.raw`docs\a.md`),
    metacharacterCase('a leading slash', '/docs/a.md'),
    metacharacterCase('a trailing slash', 'docs/a/'),
    metacharacterCase('a leading hash', '#docs/a.md'),
    metacharacterCase('a leading space', ' docs/a.md'),
    metacharacterCase('a trailing space', 'docs/a.md '),
    metacharacterCase('an embedded newline', 'docs/a.md\nwiki/'),
    metacharacterCase('an embedded carriage return', 'docs/a.md\rwiki/'),
    // git C-quotes a tab in a bare `ls-files` but not in `ls-files -z`, so an
    // exclude line carrying one masks a different file for any reader that
    // regresses to the bare form. A space is quoted by neither, which is why
    // it is allowed.
    metacharacterCase('an embedded tab', 'docs/a\tb.md'),
    metacharacterCase('an empty value', ''),
    {
      answerSet: answers({
        allowUndecided: true,
        ships: ['app/foo.ts'],
        withdraws: [withhold('app/foo.ts')],
      }),
      contains: ['duplicate_answer'],
      name: 'duplicate_answer catches a path both withdrawn and shipped',
      report: WITHDRAW_REPORT,
    },
  ])('$name', ({answerSet, contains, report = FRESH_REPORT}) => {
    const errors = validateAnswers(answerSet, report, CATEGORIES);

    for (const code of contains) {
      expect(codesOf(errors)).toContain(code);
    }
  });

  test('--allow-undecided waives exact cover and nothing else', () => {
    expect(
      validateAnswers(answers({allowUndecided: true}), FRESH_REPORT, CATEGORIES)
    ).toEqual([]);

    // Membership still applies to whatever answers were given.
    const errors = validateAnswers(
      answers({allowUndecided: true, ships: ['app/ghost.ts']}),
      FRESH_REPORT,
      CATEGORIES
    );
    expect(codesOf(errors)).toEqual(['answer_not_missing']);
  });

  test('duplicate_answer flags a path answered twice, and one answered both ways', () => {
    const twice = validateAnswers(
      answers({
        allowUndecided: true,
        ships: ['app/new.ts', 'app/new.ts'],
      }),
      FRESH_REPORT,
      CATEGORIES
    );
    expect(codesOf(twice)).toEqual(['duplicate_answer']);
    expect(twice[0]?.paths).toEqual(['app/new.ts']);

    const bothWays = validateAnswers(
      answers({
        allowUndecided: true,
        ships: ['app/new.ts'],
        withholds: [withhold('app/new.ts')],
      }),
      FRESH_REPORT,
      CATEGORIES
    );
    expect(codesOf(bothWays)).toEqual(['duplicate_answer']);
  });

  test('withdrawing a shipped path is valid and leaves exact cover to the missing set', () => {
    expect(
      validateAnswers(
        answers({
          ships: ['app/new.ts'],
          withdraws: [withhold('.github/FUNDING.yml', {category: 3})],
        }),
        WITHDRAW_REPORT,
        CATEGORIES
      )
    ).toEqual([]);

    // A withdraw answers nothing in `missing`.
    const errors = validateAnswers(
      answers({withdraws: [withhold('app/foo.ts')]}),
      WITHDRAW_REPORT,
      CATEGORIES
    );
    expect(codesOf(errors)).toEqual(['unanswered_paths']);
  });

  test('a withdraw passes the same path, reason and category checks as a withhold', () => {
    const errors = validateAnswers(
      answers({
        allowUndecided: true,
        withdraws: [
          withhold('app/foo.ts', {category: 99, reason: 'bad\nreason'}),
        ],
      }),
      {
        missing: WITHDRAW_REPORT.missing,
        shipped: ['app/foo.ts', 'app/[id].ts'],
      },
      CATEGORIES
    );
    expect(codesOf(errors)).toEqual([
      'withhold_reason_invalid',
      'unknown_category',
    ]);

    const bracketed = validateAnswers(
      answers({allowUndecided: true, withdraws: [withhold('app/[id].ts')]}),
      {missing: WITHDRAW_REPORT.missing, shipped: ['app/[id].ts']},
      CATEGORIES
    );
    expect(codesOf(bracketed)).toEqual(['withhold_metacharacter']);
  });
});
