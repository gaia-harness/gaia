import {afterEach, describe, expect, test} from 'vitest';
import {runCheck} from '../check.js';
import {
  createScratchProject,
  expectFixtureParity,
  FIXTURE_PARITY_TIMEOUT_MS,
} from '../test-support.js';
import type {Finding, FixtureProject} from '../types.js';
import {RULES_FIXTURES} from './rules.fixtures.js';
import {RULES_RULES} from './rules.js';

const cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

const RULE = '.claude/rules/example.md';

const findingsOf = (
  project: FixtureProject,
  ruleId: string
): readonly Finding[] => {
  const scratch = createScratchProject(project);

  cleanups.push(scratch.cleanup);

  return runCheck({
    catalog: RULES_RULES,
    env: scratch.env,
    root: scratch.root,
    scope: 'all',
  }).findings.filter((finding) => finding.rule_id === ruleId);
};

const ruleWithPaths = (frontmatterLines: string): FixtureProject => ({
  files: {
    'CLAUDE.md': 'Project rules.\n',
    [RULE]: `---\n${frontmatterLines}\n---\nKeep it short.\n`,
  },
  git: true,
});

describe('rules rules', () => {
  test(
    'every rule has a red fixture that fires it and a green fixture that does not',
    () => {
      expectFixtureParity(RULES_RULES, RULES_FIXTURES);
    },
    FIXTURE_PARITY_TIMEOUT_MS
  );
});

describe('rules.glob-syntax', () => {
  test('a glob picomatch rejects is a finding on the entry line', () => {
    const found = findingsOf(
      ruleWithPaths('paths:\n  - "src/**/*.ts"\n  - "{ts,tsx"'),
      'rules.glob-syntax'
    );

    expect(found).toHaveLength(1);
    expect(found[0]).toMatchObject({file: RULE, line: 4, severity: 'warning'});
  });

  test.each([
    ['an unclosed class', 'paths:\n  - "[abc"'],
    ['an unclosed group', 'paths:\n  - "a/(b"'],
    ['a non-string entry', 'paths:\n  - 42'],
    ['an empty entry', 'paths:\n  - ""'],
    ['a non-list, non-string value', 'paths:\n  nested: true'],
  ])('%s is a finding', (_name, frontmatter) => {
    expect(
      findingsOf(ruleWithPaths(frontmatter), 'rules.glob-syntax')
    ).toHaveLength(1);
  });

  test.each([
    [
      'a brace and class glob',
      'paths:\n  - "src/**/*.{ts,tsx}"\n  - "a/[bc]/*"',
    ],
    ['a single string value', 'paths: "src/**"'],
    ['no paths key', 'description: example'],
  ])('%s is clean', (_name, frontmatter) => {
    expect(findingsOf(ruleWithPaths(frontmatter), 'rules.glob-syntax')).toEqual(
      []
    );
  });
});

describe('rules.no-skill-import', () => {
  test('an import under a skills folder is a finding even when the file is absent', () => {
    expect(
      findingsOf(
        {
          files: {
            'CLAUDE.md': 'Project rules.\n',
            [RULE]: '@.claude/skills/missing/SKILL.md\n',
          },
          git: true,
        },
        'rules.no-skill-import'
      )
    ).toHaveLength(1);
  });

  test('an import elsewhere, and a mention of a skills path in prose, are clean', () => {
    expect(
      findingsOf(
        {
          files: {
            'CLAUDE.md': 'Project rules.\n',
            'docs/guide.md': '# Guide\n',
            [RULE]: '@docs/guide.md\nSee `.claude/skills/example/SKILL.md`.\n',
          },
          git: true,
        },
        'rules.no-skill-import'
      )
    ).toEqual([]);
  });
});

describe('rules.dead-path', () => {
  test('a frontmatter glob is never read as a path, and a fenced path is ignored', () => {
    expect(
      findingsOf(
        {
          files: {
            'CLAUDE.md': 'Project rules.\n',
            [RULE]:
              '---\npaths:\n  - "docs/**/*.md"\n---\n```\n`docs/fenced.md`\n```\n',
          },
          git: true,
        },
        'rules.dead-path'
      )
    ).toEqual([]);
  });

  test('a missing path is reported on its own line', () => {
    const found = findingsOf(
      {
        files: {
          'CLAUDE.md': 'Project rules.\n',
          [RULE]: 'Intro.\nRead `docs/missing.md`.\n',
        },
        git: true,
      },
      'rules.dead-path'
    );

    expect(found).toMatchObject([{file: RULE, line: 2}]);
  });
});
