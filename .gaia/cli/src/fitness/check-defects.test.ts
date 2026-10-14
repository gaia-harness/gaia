import {describe, expect, test} from 'vitest';
import {createHash, randomBytes} from 'node:crypto';
import {existsSync, readdirSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {
  checkProject,
  findingsOfRule,
  leakedPieces,
  registerScratchProjects,
  reportOf,
} from './check-support.js';
import {compareBytes} from './markdown.js';
import {
  commandFile,
  filler,
  linesWithContents,
  skillFile,
} from './rules/authoring.fixtures.js';
import type {FixtureProject} from './types.js';

const scratch = registerScratchProjects();

type Defect = {
  file: string;
  ruleId: string;
};

/** Every defect the red project carries, by the file that carries it. */
const DEFECTS: readonly Defect[] = [
  {
    file: '.claude/skills/long-name/SKILL.md',
    ruleId: 'frontmatter.skill.name.max-length',
  },
  {
    file: '.claude/skills/reserved/SKILL.md',
    ruleId: 'frontmatter.skill.name.reserved-word',
  },
  {
    file: '.claude/skills/long-description/SKILL.md',
    ruleId: 'frontmatter.skill.description.max-length',
  },
  {
    file: '.claude/skills/xml-description/SKILL.md',
    ruleId: 'frontmatter.skill.description.xml-tag',
  },
  {
    file: '.claude/skills/first-person/SKILL.md',
    ruleId: 'authoring.skill.description.first-person',
  },
  {
    file: '.claude/skills/empty-description/SKILL.md',
    ruleId: 'frontmatter.skill.description.non-empty',
  },
  {
    file: '.claude/skills/yaml-hazard/SKILL.md',
    ruleId: 'frontmatter.yaml-hazard',
  },
  {
    file: '.claude/commands/xml-command.md',
    ruleId: 'frontmatter.skill.description.xml-tag',
  },
  {
    file: '.claude/skills/long-body/SKILL.md',
    ruleId: 'authoring.skill.body.max-lines',
  },
  {
    file: '.claude/skills/references/references/long.md',
    ruleId: 'authoring.reference.toc.required',
  },
  {
    file: '.claude/skills/references/references/chain-a.md',
    ruleId: 'authoring.reference.depth.one-level',
  },
  {
    file: '.claude/skills/backslash/SKILL.md',
    ruleId: 'authoring.path.windows-separator',
  },
  {file: '.claude/playbooks/run.md', ruleId: 'authoring.playbook.max-lines'},
];

const GOOD = 'Reviews code for defects. Use when a review is asked.';

/** The defect project (`fixed: false`) or the identical project with every defect repaired. */
const defectProject = (fixed: boolean): FixtureProject => ({
  files: {
    '.claude/commands/playbook-entry.md': commandFile(
      'Read `.claude/playbooks/run.md` and follow it.\n'
    ),
    '.claude/commands/xml-command.md': commandFile(
      'Body.\n',
      fixed ? GOOD : 'Runs <tag> checks. Use when a check is asked.'
    ),
    '.claude/playbooks/run.md': linesWithContents(fixed ? 100 : 510),
    '.claude/skills/backslash/SKILL.md': skillFile(
      fixed ? 'Open docs/guide.md first.\n' : 'Open docs\\guide.md first.\n',
      {description: GOOD, name: 'backslash'}
    ),
    '.claude/skills/empty-description/SKILL.md': skillFile('Body.\n', {
      description: fixed ? GOOD : "''",
      name: 'empty-description',
    }),
    '.claude/skills/first-person/SKILL.md': skillFile('Body.\n', {
      description:
        fixed ?
          'Reviews code whenever a review is asked.'
        : 'Helps me review code whenever a review is asked.',
      name: 'first-person',
    }),
    '.claude/skills/long-body/SKILL.md': skillFile(
      linesWithContents(fixed ? 100 : 520),
      {description: GOOD, name: 'long-body'}
    ),
    '.claude/skills/long-description/SKILL.md': skillFile('Body.\n', {
      description:
        fixed ? GOOD : `Reviews code. Use when asked. ${'word '.repeat(220)}`,
      name: 'long-description',
    }),
    '.claude/skills/long-name/SKILL.md': skillFile('Body.\n', {
      description: GOOD,
      name: fixed ? 'long-name' : `long-name-${'x'.repeat(60)}`,
    }),
    '.claude/skills/references/references/chain-a.md':
      'Next, see [b](deep/chain-b.md).\n',
    '.claude/skills/references/references/deep/chain-b.md': 'Leaf.\n',
    '.claude/skills/references/references/long.md':
      fixed ? linesWithContents(140) : filler(140),
    '.claude/skills/references/SKILL.md': skillFile(
      fixed ?
        'See [a](references/chain-a.md), [b](references/deep/chain-b.md) and [long](references/long.md).\n'
      : 'See [a](references/chain-a.md) and [long](references/long.md).\n',
      {description: GOOD, name: 'references'}
    ),
    '.claude/skills/reserved/SKILL.md': skillFile('Body.\n', {
      description: GOOD,
      name: fixed ? 'code-helper' : 'claude-helper',
    }),
    '.claude/skills/xml-description/SKILL.md': skillFile('Body.\n', {
      description: fixed ? GOOD : 'Reviews <script> blocks. Use when asked.',
      name: 'xml-description',
    }),
    '.claude/skills/yaml-hazard/SKILL.md': skillFile('Body.\n', {
      description:
        fixed ?
          "'Reviews code: carefully, whenever asked.'"
        : 'Reviews code: carefully, whenever asked.',
      name: 'yaml-hazard',
    }),
    'CLAUDE.md': '# Project\n\nA short project note.\n',
  },
  git: true,
});

const hashTree = (root: string): Record<string, string> => {
  const hashes: Record<string, string> = {};

  const walk = (directory: string): void => {
    for (const entry of readdirSync(directory).filter(
      (name) => name !== '.git'
    )) {
      const absolute = path.join(directory, entry);

      if (statSync(absolute).isDirectory()) walk(absolute);
      else {
        hashes[path.relative(root, absolute)] = createHash('sha256')
          .update(readFileSync(absolute))
          .digest('hex');
      }
    }
  };

  walk(root);

  return hashes;
};

const keyOf = (ruleId: string, file: string): string => `${ruleId} @ ${file}`;

describe('gaia fitness check on frontmatter and authoring defects', () => {
  test('reports each defect once, as a warning, and modifies nothing', async () => {
    const project = scratch(defectProject(false));
    const before = hashTree(project.root);
    const report = reportOf(await checkProject(project));
    const after = hashTree(project.root);

    expect(Object.keys(before).length).toBeGreaterThan(DEFECTS.length);
    expect(after).toEqual(before);

    const warnings = report.findings
      .filter((finding) => finding.severity === 'warning')
      .map((finding) => keyOf(finding.rule_id, finding.file))
      .toSorted(compareBytes);

    expect(warnings).toEqual(
      DEFECTS.map(({file, ruleId}) => keyOf(ruleId, file)).toSorted(
        compareBytes
      )
    );
    expect(
      report.findings.some((finding) => finding.severity === 'error')
    ).toBe(false);
  });

  test('the same project with each defect repaired reports none of those rules', async () => {
    const report = reportOf(await checkProject(scratch(defectProject(true))));
    const defectRuleIds = new Set(DEFECTS.map(({ruleId}) => ruleId));

    expect(
      report.findings.filter((finding) => defectRuleIds.has(finding.rule_id))
    ).toEqual([]);
    expect(
      report.findings.filter((finding) => finding.severity !== 'info')
    ).toEqual([]);
  });
});

const REPAIRED_RULE_IDS = [
  'hooks.path-exists-executable',
  'hooks.rooted-command',
  'settings.env-secrets',
  'claudemd.imports-resolve',
  'claudemd.dead-path',
];

const SECRET_FIELDS = ['message', 'remediation', 'file'] as const;

const hostileProject = (secret: string): FixtureProject => ({
  files: {
    'CLAUDE.md':
      '# Project\n\nImports follow.\n\n@docs/missing-import.md\n\nSee `docs/missing-path.md` for detail.\n',
    'docs/index.md': '# Docs\n',
  },
  git: true,
  settingsJson: {
    env: {ANTHROPIC_API_KEY: secret},
    hooks: {
      PreToolUse: [
        {
          hooks: [
            {
              command: '"$CLAUDE_PROJECT_DIR"/.claude/hooks/missing.sh',
              type: 'command',
            },
            {command: '.claude/hooks/example.sh', type: 'command'},
            {command: '$(touch sentinel)', type: 'command'},
          ],
          matcher: 'Bash',
        },
      ],
    },
  },
});

const repairedHostileProject = (): FixtureProject => ({
  files: {
    'CLAUDE.md': '# Project\n\nA short project note.\n',
  },
  git: true,
  settingsJson: {
    hooks: {
      PreToolUse: [
        {
          hooks: [{command: '$HOME/hooks/example.sh', type: 'command'}],
          matcher: 'Bash',
        },
      ],
    },
  },
});

describe('gaia fitness check on hooks, secrets and paths together', () => {
  test('reports the errors and the warning with a file and line, leaking nothing and executing nothing', async () => {
    const secret = `sk-ant-${randomBytes(16).toString('hex')}`;
    const project = scratch(hostileProject(secret));
    const run = await checkProject(project);
    const report = reportOf(run);
    const of = (ruleId: string) => findingsOfRule(report, ruleId);

    expect(run.exitCode).toBe(1);

    const expected: [string, string, string][] = [
      ['hooks.path-exists-executable', 'error', '.claude/settings.json'],
      ['hooks.rooted-command', 'error', '.claude/settings.json'],
      ['settings.env-secrets', 'error', '.claude/settings.json'],
      ['claudemd.imports-resolve', 'error', 'CLAUDE.md'],
      ['claudemd.dead-path', 'warning', 'CLAUDE.md'],
    ];

    const observed = expected.map(([ruleId]) => {
      const found = of(ruleId);

      return [
        ruleId,
        found.length,
        found[0]?.severity,
        found[0]?.file,
        (found[0]?.line ?? 0) > 0,
      ];
    });

    expect(observed).toEqual(
      expected.map(([ruleId, severity, file]) => [
        ruleId,
        1,
        severity,
        file,
        true,
      ])
    );

    expect(of('settings.env-secrets')[0]?.message).toContain(
      'ANTHROPIC_API_KEY'
    );

    for (const finding of report.findings) {
      for (const field of SECRET_FIELDS) {
        expect(finding[field]).not.toContain(secret.slice(7));
      }
    }

    expect(leakedPieces(secret, [run.stdout, run.stderr])).toEqual([]);

    expect(existsSync(path.join(project.root, 'sentinel'))).toBe(false);
    expect(existsSync(path.join(process.cwd(), 'sentinel'))).toBe(false);
  });

  test('the repaired twin reports none of those rules', async () => {
    const report = reportOf(
      await checkProject(scratch(repairedHostileProject()))
    );
    const ids = new Set(report.findings.map((finding) => finding.rule_id));

    expect(REPAIRED_RULE_IDS.filter((ruleId) => ids.has(ruleId))).toEqual([]);
  });
});
