import {describe, expect, test} from 'vitest';
import {
  checkProject,
  cleanProject,
  findingsOfCategory,
  gradeOf,
  registerScratchProjects,
  registerTemporaryDirectories,
  reportOf,
  writeFailingClassifier,
} from './check-support.js';
import {OWNERSHIP_CLASSIFIER_ENV} from './ownership.js';
import {linesWithContents, skillFile} from './rules/authoring.fixtures.js';
import type {FixtureProject} from './types.js';

const scratch = registerScratchProjects();
const temporaryDirectory = registerTemporaryDirectories();

/** The clean project with `files` and `settingsJson` replaced where given. */
const variant = (
  changes: Partial<FixtureProject> & {removeFiles?: readonly string[]}
): FixtureProject => {
  const base = cleanProject();
  const files = {...base.files, ...changes.files};

  for (const removed of changes.removeFiles ?? []) delete files[removed];

  return {
    ...base,
    ...(changes.settingsJson === undefined ?
      {}
    : {settingsJson: changes.settingsJson}),
    files,
  };
};

/** Hook commands that name `count` distinct scripts missing from the project. */
const missingHooks = (count: number): unknown => ({
  hooks: {
    PreToolUse: [
      {
        hooks: Array.from({length: count}, (_, index) => ({
          command: `"$CLAUDE_PROJECT_DIR"/.claude/hooks/missing-${index}.sh`,
          type: 'command',
        })),
        matcher: 'Bash',
      },
    ],
  },
});

const duplicatePermissions = (duplicates: number): unknown => ({
  permissions: {
    allow: Array.from({length: duplicates + 1}, () => 'Read'),
  },
});

const deadPaths = (count: number): Record<string, string> => ({
  'CLAUDE.md': `# Project\n\n${Array.from(
    {length: count},
    (_, index) => `See \`docs/missing-${index}.md\` for detail.`
  ).join('\n\n')}\n`,
  'docs/index.md': '# Docs\n',
});

type GradeCase = {
  category: string;
  expectedFindings: number;
  expectedGrade: string;
  name: string;
  project: () => FixtureProject;
};

const GRADE_CASES: readonly GradeCase[] = [
  {
    category: 'settings',
    expectedFindings: 0,
    expectedGrade: 'A+',
    name: 'no findings',
    project: () => variant({}),
  },
  {
    category: 'settings',
    expectedFindings: 2,
    expectedGrade: 'A',
    name: 'two info findings',
    project: () => variant({settingsJson: duplicatePermissions(2)}),
  },
  {
    category: 'claudemd',
    expectedFindings: 1,
    expectedGrade: 'B+',
    name: 'one warning',
    project: () => variant({files: deadPaths(1)}),
  },
  {
    category: 'claudemd',
    expectedFindings: 3,
    expectedGrade: 'B-',
    name: 'three warnings',
    project: () => variant({files: deadPaths(3)}),
  },
  {
    category: 'hooks',
    expectedFindings: 1,
    expectedGrade: 'C+',
    name: 'one error',
    project: () => variant({settingsJson: missingHooks(1)}),
  },
  {
    category: 'hooks',
    expectedFindings: 7,
    expectedGrade: 'D-',
    name: 'seven errors',
    project: () => variant({settingsJson: missingHooks(7)}),
  },
  {
    category: 'settings',
    expectedFindings: 1,
    expectedGrade: 'F',
    name: 'an unparseable settings file',
    project: () => ({
      ...variant({files: {'.claude/settings.json': '{ not json'}}),
      settingsJson: undefined,
    }),
  },
  {
    category: 'claudemd',
    expectedFindings: 1,
    expectedGrade: 'F',
    name: 'no root CLAUDE.md',
    project: () => variant({removeFiles: ['CLAUDE.md']}),
  },
  {
    category: 'wiki',
    expectedFindings: 0,
    expectedGrade: 'n/a',
    name: 'no wiki directory',
    project: () => variant({}),
  },
  {
    category: 'hooks',
    expectedFindings: 0,
    expectedGrade: 'n/a',
    name: 'no hooks configured',
    project: () => variant({}),
  },
  {
    category: 'settings',
    expectedFindings: 40,
    expectedGrade: 'A-',
    name: 'forty info findings',
    project: () => variant({settingsJson: duplicatePermissions(40)}),
  },
];

const GRADE_ORDER = [
  'F',
  'D-',
  'D',
  'D+',
  'C-',
  'C',
  'C+',
  'B-',
  'B',
  'B+',
  'A-',
  'A',
  'A+',
];

describe('gaia fitness check grades', () => {
  test.each(GRADE_CASES)(
    '$name grades $category as $expectedGrade',
    async ({category, expectedFindings, expectedGrade, project}) => {
      const report = reportOf(await checkProject(scratch(project())));
      const inCategory = findingsOfCategory(report, category);

      expect(inCategory).toHaveLength(expectedFindings);
      expect(gradeOf(report, category)).toBe(expectedGrade);

      const graded = report.categories
        .map((entry) => entry.grade)
        .filter((grade) => grade !== 'n/a');
      const lowest = graded.toSorted(
        (a, b) => GRADE_ORDER.indexOf(a) - GRADE_ORDER.indexOf(b)
      )[0];

      expect(graded.length).toBeGreaterThan(0);
      expect(report.overall).toBe(lowest);
    }
  );
});

const oneWarning = (): FixtureProject => variant({files: deadPaths(1)});
const oneAuthoringWarning = (): FixtureProject =>
  variant({
    files: {
      '.claude/skills/example/SKILL.md': skillFile(linesWithContents(520), {
        description: 'Summarizes the example status. Use when asked.',
      }),
    },
  });

describe('gaia fitness check exit codes', () => {
  test.each([
    ['a clean project', () => cleanProject(), [], 0],
    ['one error', () => variant({settingsJson: missingHooks(1)}), [], 1],
    ['one warning', oneWarning, [], 0],
    [
      'one warning with --fail-on warning',
      oneWarning,
      ['--fail-on', 'warning'],
      1,
    ],
    ['one authoring warning', oneAuthoringWarning, [], 0],
    [
      'one authoring warning enforced by category',
      oneAuthoringWarning,
      ['--enforce', 'authoring'],
      1,
    ],
    [
      'one authoring warning with another category enforced',
      oneAuthoringWarning,
      ['--enforce', 'prompt'],
      0,
    ],
    ['an unknown flag', () => cleanProject(), ['--bogus'], 2],
  ] as const)('%s exits %i', async (_name, project, extra, expected) => {
    const run = await checkProject(scratch(project()), ...extra);

    expect(run.exitCode).toBe(expected);
  });

  test('the authoring warning is the one the enforce flag acts on', async () => {
    const report = reportOf(await checkProject(scratch(oneAuthoringWarning())));

    expect(report.findings.map((finding) => finding.rule_id)).toEqual([
      'authoring.skill.body.max-lines',
    ]);
    expect(report.findings[0]?.severity).toBe('warning');
  });

  test('a root that is not a directory exits 3', async () => {
    const project = scratch(cleanProject());
    const notDirectory = `${project.root}/CLAUDE.md`;
    const run = await checkProject({...project, root: notDirectory});

    expect(run.exitCode).toBe(3);
    expect(run.stdout).toBe('');
  });

  test('a classifier that cannot run leaves every finding and file unknown yet still graded', async () => {
    const stub = writeFailingClassifier(temporaryDirectory());
    const informational: FixtureProject = variant({
      files: {
        '.claude/skills/example/SKILL.md': skillFile('# Example\n\nBody.\n', {
          description:
            'Summarizes the example status when you ask for a status summary.',
        }),
      },
    });

    const withRepoClassifier = reportOf(
      await checkProject(scratch(informational))
    );
    const withStub = await checkProject({
      ...scratch({...informational, classifier: stub}),
      env: {[OWNERSHIP_CLASSIFIER_ENV]: stub},
    });
    const stubbed = reportOf(withStub);

    expect(withRepoClassifier.findings.length).toBeGreaterThan(0);
    expect(
      withRepoClassifier.findings.every(
        (finding) => finding.ownership === 'adopter'
      )
    ).toBe(true);
    expect(
      withRepoClassifier.inventory.every((file) => file.ownership === 'adopter')
    ).toBe(true);

    expect(withStub.exitCode).toBe(0);
    expect(stubbed.findings).toHaveLength(withRepoClassifier.findings.length);
    expect(
      stubbed.findings.every((finding) => finding.ownership === 'unknown')
    ).toBe(true);
    expect(stubbed.inventory.length).toBeGreaterThan(0);
    expect(
      stubbed.inventory.every((file) => file.ownership === 'unknown')
    ).toBe(true);
    expect(stubbed.overall).toBe(withRepoClassifier.overall);
  });
});
