import {describe, expect, test} from 'vitest';
import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {
  checkProject,
  cleanProject,
  findingsOfRule,
  gradeOf,
  registerScratchProjects,
  reportOf,
} from './check-support.js';
import {linesWithContents, skillFile} from './rules/authoring.fixtures.js';
import type {CheckReport, Finding, FixtureProject} from './types.js';

const scratch = registerScratchProjects();

const GOOD = 'Reviews code for defects. Use when a review is asked.';
const LONG_DESCRIPTION = `Reviews code. Use when asked. ${'word '.repeat(220)}`;

describe('gaia fitness check scoping to what the project owns', () => {
  const shippedSkill = '.claude/skills/shipped/SKILL.md';

  const projectWithShippedSkill = (owned: boolean): FixtureProject => {
    const base = cleanProject();

    return {
      ...base,
      files: {
        ...base.files,
        [shippedSkill]: skillFile(linesWithContents(520), {
          description: GOOD,
          name: 'shipped',
        }),
      },
      manifest: {files: owned ? {[shippedSkill]: 'owned'} : {}},
    };
  };

  test('lists a GAIA-owned file defect as upstream by default and grades it under the all scope', async () => {
    const project = scratch(projectWithShippedSkill(true));
    const byDefault = reportOf(await checkProject(project));
    const everything = reportOf(await checkProject(project, '--scope', 'all'));

    expect(byDefault.overall).toBe('A+');
    expect(byDefault.findings).toEqual([]);
    expect(byDefault.upstream).toHaveLength(1);
    expect(byDefault.upstream[0]?.rule_id).toBe(
      'authoring.skill.body.max-lines'
    );
    expect(byDefault.upstream[0]?.file).toBe(shippedSkill);
    expect(byDefault.upstream[0]?.remediation).toContain('/update-gaia');

    expect(everything.upstream).toEqual([]);
    expect(
      findingsOfRule(everything, 'authoring.skill.body.max-lines')
    ).toHaveLength(1);
    expect(['B+', 'B', 'B-', 'C+', 'C', 'C-', 'D+', 'D', 'D-', 'F']).toContain(
      gradeOf(everything, 'authoring')
    );
  });

  test('grades the same defect on a file the manifest does not own', async () => {
    const report = reportOf(
      await checkProject(scratch(projectWithShippedSkill(false)))
    );

    expect(report.upstream).toEqual([]);
    expect(
      findingsOfRule(report, 'authoring.skill.body.max-lines')
    ).toHaveLength(1);
    expect(gradeOf(report, 'authoring')).toBe('B+');
    expect(report.overall).toBe('B+');
  });
});

describe('gaia fitness check on third-party and untracked files', () => {
  const vendoredSkill = '.claude/skills/vendored/SKILL.md';
  const untrackedSkill = '.claude/skills/untracked/SKILL.md';
  const adopterSkill = '.claude/skills/adopter/SKILL.md';

  const projectWithDefects = (withAdopterTwin: boolean): FixtureProject => {
    const base = cleanProject();

    return {
      ...base,
      files: {
        ...base.files,
        [vendoredSkill]: skillFile('Body.\n', {
          description: LONG_DESCRIPTION,
          name: 'vendored',
        }),
        ...(withAdopterTwin ?
          {
            [adopterSkill]: skillFile('Body.\n', {
              description: LONG_DESCRIPTION,
              name: 'adopter',
            }),
          }
        : {}),
      },
      vendorPins: {pinned: '.claude/skills/vendored'},
    };
  };

  /** Writes a skill with the same defect after the commit, so git does not track it. */
  const addUntrackedSkill = (root: string): void => {
    const absolute = path.join(root, untrackedSkill);

    mkdirSync(path.dirname(absolute), {recursive: true});
    writeFileSync(
      absolute,
      skillFile('Body.\n', {description: LONG_DESCRIPTION, name: 'untracked'})
    );
  };

  test('reports nothing for a vendored skill or an untracked skill and inventories the vendored one as third-party', async () => {
    const project = scratch(projectWithDefects(false));

    addUntrackedSkill(project.root);

    const run = await checkProject(project, '--enforce', 'frontmatter');
    const report = reportOf(run);
    const named = [
      ...report.findings,
      ...report.upstream,
      ...report.suppressed,
    ];

    expect(run.exitCode).toBe(0);
    expect(
      named.filter((finding) => finding.file.includes('vendored'))
    ).toEqual([]);
    expect(
      named.filter((finding) => finding.file.includes('untracked'))
    ).toEqual([]);
    expect(
      report.inventory.find((entry) => entry.path === vendoredSkill)?.ownership
    ).toBe('third-party');
    expect(
      report.inventory.some((entry) => entry.path === untrackedSkill)
    ).toBe(false);
  });

  test('fails the same enforced run once an adopter skill carries the defect', async () => {
    const project = scratch(projectWithDefects(true));

    addUntrackedSkill(project.root);

    const run = await checkProject(project, '--enforce', 'frontmatter');
    const report = reportOf(run);

    expect(run.exitCode).toBe(1);
    expect(report.findings.map((finding) => finding.file)).toEqual([
      adopterSkill,
    ]);
    expect(report.findings[0]?.rule_id).toBe(
      'frontmatter.skill.description.max-length'
    );
  });
});

type Located = {
  bucket: 'findings' | 'suppressed' | 'upstream';
  finding: Finding;
};

const locate = (
  report: CheckReport,
  ruleId: string,
  file: string
): Located | undefined => {
  for (const bucket of ['findings', 'upstream', 'suppressed'] as const) {
    const finding = report[bucket].find(
      (candidate) => candidate.rule_id === ruleId && candidate.file === file
    );

    if (finding !== undefined) return {bucket, finding};
  }

  return undefined;
};

const MISSING_HOOK = {
  hooks: {
    PreToolUse: [
      {
        hooks: [
          {
            command: '"$CLAUDE_PROJECT_DIR"/.claude/hooks/missing.sh',
            type: 'command',
          },
        ],
        matcher: 'Bash',
      },
    ],
  },
};

const SHIPPED_SETTINGS = '.claude/settings.json';
const ADOPTER_SETTINGS = 'frontend/.claude/settings.json';

/** A project with one adopter file per fixable category plus every file class that must stay out of the heal. */
const fixableProject = (secret: string): FixtureProject => ({
  files: {
    '.claude/gaia-fitness.json': `${JSON.stringify({
      ignore: [
        {
          path: 'frontend/CLAUDE.md',
          reason: 'A documented exception.',
          rule_id: 'claudemd.dead-path',
        },
      ],
      version: 1,
    })}\n`,
    '.claude/rules/example.md':
      '# Example\n\nSee `docs/missing-rule-path.md`.\n',
    '.claude/skills/installed/SKILL.md': skillFile('Body.\n', {
      description: LONG_DESCRIPTION,
      name: 'installed',
    }),
    '.claude/skills/long/SKILL.md': skillFile(linesWithContents(520), {
      description: GOOD,
      name: 'long',
    }),
    '.claude/skills/tags/SKILL.md': skillFile('</note> unbalanced.\n', {
      description: GOOD,
      name: 'tags',
    }),
    '.claude/skills/vendored/SKILL.md': skillFile('Body.\n', {
      description: LONG_DESCRIPTION,
      name: 'vendored',
    }),
    '.gitignore': '.claude/skills/installed/\n',
    [ADOPTER_SETTINGS]: `${JSON.stringify({
      ...MISSING_HOOK,
      env: {ANTHROPIC_API_KEY: secret},
      permissions: {allow: ['Read', 'Read']},
    })}\n`,
    'CLAUDE.md': '# Project\n\nSee `docs/missing-claude-path.md`.\n',
    'docs/index.md': '# Docs\n',
    'frontend/CLAUDE.md':
      '# Frontend\n\nSee `docs/missing-frontend-path.md`.\n',
  },
  git: true,
  manifest: {files: {[SHIPPED_SETTINGS]: 'owned'}},
  settingsJson: MISSING_HOOK,
  vendorPins: {pinned: '.claude/skills/vendored'},
});

type FixableCase = {
  bucket: Located['bucket'];
  file: string;
  fixable: boolean;
  name: string;
  ruleId: string;
};

const ADOPTER_CASES: readonly FixableCase[] = [
  {
    bucket: 'findings',
    file: ADOPTER_SETTINGS,
    fixable: true,
    name: 'an adopter hooks error',
    ruleId: 'hooks.path-exists-executable',
  },
  {
    bucket: 'findings',
    file: ADOPTER_SETTINGS,
    fixable: true,
    name: 'an adopter settings error',
    ruleId: 'settings.env-secrets',
  },
  {
    bucket: 'findings',
    file: 'CLAUDE.md',
    fixable: true,
    name: 'an adopter claudemd warning',
    ruleId: 'claudemd.dead-path',
  },
  {
    bucket: 'findings',
    file: '.claude/rules/example.md',
    fixable: true,
    name: 'an adopter rules warning',
    ruleId: 'rules.dead-path',
  },
  {
    bucket: 'findings',
    file: '.claude/skills/long/SKILL.md',
    fixable: false,
    name: 'an adopter authoring warning',
    ruleId: 'authoring.skill.body.max-lines',
  },
  {
    bucket: 'findings',
    file: '.claude/skills/tags/SKILL.md',
    fixable: false,
    name: 'an adopter prompt warning',
    ruleId: 'prompt.xml-tag-balance',
  },
  {
    bucket: 'findings',
    file: ADOPTER_SETTINGS,
    fixable: false,
    name: 'an adopter info finding',
    ruleId: 'settings.redundant-permissions',
  },
  {
    bucket: 'suppressed',
    file: 'frontend/CLAUDE.md',
    fixable: false,
    name: 'a suppressed claudemd warning',
    ruleId: 'claudemd.dead-path',
  },
  {
    bucket: 'upstream',
    file: SHIPPED_SETTINGS,
    fixable: false,
    name: 'a GAIA-shipped hooks error listed as upstream',
    ruleId: 'hooks.path-exists-executable',
  },
];

describe('gaia fitness check fixable flags', () => {
  const secret = `sk-ant-${'0123456789abcdef'.repeat(2)}`;

  test.each(ADOPTER_CASES)(
    'marks $name fixable=$fixable',
    async ({bucket, file, fixable, ruleId}) => {
      const report = reportOf(
        await checkProject(scratch(fixableProject(secret)))
      );
      const located = locate(report, ruleId, file);

      expect(located, `${ruleId} on ${file}`).toBeDefined();
      expect(located?.bucket).toBe(bucket);
      expect(located?.finding.fixable).toBe(fixable);
    }
  );

  test('marks a GAIA-shipped hooks error graded under the all scope as not fixable', async () => {
    const report = reportOf(
      await checkProject(scratch(fixableProject(secret)), '--scope', 'all')
    );
    const located = locate(
      report,
      'hooks.path-exists-executable',
      SHIPPED_SETTINGS
    );

    expect(located?.bucket).toBe('findings');
    expect(located?.finding.ownership).toBe('gaia-shipped');
    expect(located?.finding.fixable).toBe(false);
  });

  test('marks the same warning not fixable when ownership is unknown', async () => {
    const unknown = scratch({...fixableProject(secret), classifier: 'none'});
    const report = reportOf(await checkProject(unknown));
    const located = locate(report, 'claudemd.dead-path', 'CLAUDE.md');

    expect(located?.bucket).toBe('findings');
    expect(located?.finding.ownership).toBe('unknown');
    expect(located?.finding.fixable).toBe(false);
    expect(report.findings.every((finding) => !finding.fixable)).toBe(true);
  });

  test('yields no finding at all for a vendored or an installer-managed file', async () => {
    const report = reportOf(
      await checkProject(scratch(fixableProject(secret)))
    );
    const named = [
      ...report.findings,
      ...report.upstream,
      ...report.suppressed,
    ];

    expect(
      named.filter(
        (finding) =>
          finding.file.includes('vendored') ||
          finding.file.includes('installed')
      )
    ).toEqual([]);

    expect(
      report.inventory.find(
        (entry) => entry.path === '.claude/skills/vendored/SKILL.md'
      )?.ownership
    ).toBe('third-party');
    expect(
      report.inventory.some((entry) => entry.path.includes('installed'))
    ).toBe(false);
  });
});
