import {describe, expect, test} from 'vitest';
import {symlinkSync} from 'node:fs';
import path from 'node:path';
import {
  registerScratchProjects,
  registerTemporaryDirectories,
} from '../check-support.js';
import {runCheck} from '../check.js';
import type {Finding, FixtureProject} from '../types.js';

const createProject = registerScratchProjects();
const createTemporaryDirectory = registerTemporaryDirectories();

const reportFindings = (project: FixtureProject): Finding[] => {
  const scratch = createProject(project);

  return [
    ...runCheck({
      env: scratch.env,
      root: scratch.root,
      scope: 'all',
    }).findings,
  ];
};

const findingsOf = (project: FixtureProject, ruleId: string): Finding[] =>
  reportFindings(project).filter((finding) => finding.rule_id === ruleId);

const skill = (body: string): string =>
  `---\nname: example\ndescription: Reviews code for defects. Use when a review is asked.\n---\n${body}`;

const rule = (body: string): FixtureProject => ({
  files: {'.claude/rules/example.md': body, 'CLAUDE.md': 'Root.\n'},
  git: true,
});

const nestedClaudeMd = (withTarget: boolean): FixtureProject => ({
  files: {
    'CLAUDE.md': 'Root.\n',
    'pkg/app/other.ts': 'export {};\n',
    'pkg/CLAUDE.md': 'Code lives in `app/index.ts`.\n',
    ...(withTarget ? {'pkg/app/index.ts': 'export {};\n'} : {}),
  },
  git: true,
});

const nestedRule = (withTarget: boolean): FixtureProject => ({
  files: {
    '.claude/rules/example.md': 'Root.\n',
    'CLAUDE.md': 'Root.\n',
    'pkg/.claude/rules/example.md': 'Config is `config/app.json`.\n',
    'pkg/config/other.json': '{}\n',
    ...(withTarget ? {'pkg/config/app.json': '{}\n'} : {}),
  },
  git: true,
});

const bareName = (withTarget: boolean): FixtureProject => ({
  files: {
    '.claude/rules/example.md': 'See `shared-lib.sh` for the helper.\n',
    'CLAUDE.md': 'Root.\n',
    ...(withTarget ? {'scripts/shared-lib.sh': '#!/bin/sh\n'} : {}),
  },
  git: true,
});

const generatedReference = (ignored: boolean): FixtureProject => ({
  files: {
    '.claude/skills/example/references/other.md': 'Other.\n',
    '.claude/skills/example/SKILL.md': skill(
      'Output lands in `references/generated.md`.\n'
    ),
    'CLAUDE.md': 'Root.\n',
    ...(ignored ?
      {'.gitignore': '.claude/skills/example/references/generated.md\n'}
    : {}),
  },
  git: true,
});

const scoped = (body: string): FixtureProject => ({
  files: {
    'CLAUDE.md': 'Root.\n',
    'pkg/.claude/rules/example.md': `---\npaths:\n  - 'app/**'\n---\n${body}`,
    'pkg/app/components/ui/button.tsx': 'export {};\n',
  },
  git: true,
});

const specifier = (name: string): FixtureProject => ({
  files: {
    '.claude/rules/example.md': `Mock with \`test/mocks/${name}\`.\n`,
    'CLAUDE.md': 'Root.\n',
    'test/mocks/database.ts': 'export {};\n',
  },
  git: true,
});

describe('paths written relative to a nested package', () => {
  test('a nested CLAUDE.md path resolves against its own folder', () => {
    expect(findingsOf(nestedClaudeMd(true), 'claudemd.dead-path')).toEqual([]);
    expect(
      findingsOf(nestedClaudeMd(false), 'claudemd.dead-path')
    ).toHaveLength(1);
  });

  test('a rule under a nested .claude folder resolves against the folder holding that .claude', () => {
    expect(findingsOf(nestedRule(true), 'rules.dead-path')).toEqual([]);
    expect(findingsOf(nestedRule(false), 'rules.dead-path')).toHaveLength(1);
  });

  test('a root rule is not resolved against an unrelated folder', () => {
    expect(
      findingsOf(
        {
          files: {
            '.claude/rules/example.md': 'Config is `config/app.json`.\n',
            'CLAUDE.md': 'Root.\n',
            'config/other.json': '{}\n',
            'pkg/config/app.json': '{}\n',
          },
          git: true,
        },
        'rules.dead-path'
      )
    ).toHaveLength(1);
  });
});

describe('a file name without a folder', () => {
  test('is not reported when a tracked file carries that name', () => {
    expect(findingsOf(bareName(true), 'rules.dead-path')).toEqual([]);
  });

  test('is not reported when no tracked file carries that name', () => {
    expect(findingsOf(bareName(false), 'rules.dead-path')).toEqual([]);
  });

  test('is not reported as a folder name, an example or a negation', () => {
    expect(
      findingsOf(
        rule(
          'Tests live in `tests/`. The project ships no `tailwind.config.ts`; the run writes `STATE.md`.\n'
        ),
        'rules.dead-path'
      )
    ).toEqual([]);
  });

  test('is still dead when it is a markdown link', () => {
    expect(
      findingsOf(rule('See [the guide](guide.md).\n'), 'rules.dead-path')
    ).toHaveLength(1);
  });
});

describe('an ignored folder that is a symlink', () => {
  test('keeps its contents from being reported as broken links', () => {
    const scratch = createProject({
      files: {
        '.claude/commands/example.md':
          '---\ndescription: Runs the example. Use when asked.\n---\nState lives in `.gaia/local/state.json`.\n',
        '.gitignore': '.gaia/local\n',
        'CLAUDE.md': 'Root.\n',
      },
      git: true,
    });
    const target = createTemporaryDirectory();

    symlinkSync(target, path.join(scratch.root, '.gaia/local'));

    const report = runCheck({
      env: scratch.env,
      root: scratch.root,
      scope: 'all',
    });

    expect(
      report.findings.filter(
        (finding) => finding.rule_id === 'authoring.reference.link.resolves'
      )
    ).toEqual([]);
  });
});

describe('a gitignored link target in a skill', () => {
  test('is a runtime artifact, not a broken link', () => {
    expect(
      findingsOf(generatedReference(true), 'authoring.reference.link.resolves')
    ).toEqual([]);
  });

  test('is a broken link when git does not ignore it', () => {
    expect(
      findingsOf(generatedReference(false), 'authoring.reference.link.resolves')
    ).toHaveLength(1);
  });
});

describe('a rule path written relative to its paths: scope', () => {
  test('resolves against the static prefix of the paths: glob', () => {
    expect(
      findingsOf(
        scoped('`components/ui/` holds `components/ui/button.tsx`.\n'),
        'rules.dead-path'
      )
    ).toEqual([]);
  });

  test('is dead when the scoped folder exists and the file does not', () => {
    expect(
      findingsOf(scoped('See `components/ui/gone.tsx`.\n'), 'rules.dead-path')
    ).toHaveLength(1);
  });
});

describe('a backticked token whose first folder exists nowhere', () => {
  test('is a lint rule id, a package subpath or a placeholder, not a dead path', () => {
    expect(
      findingsOf(
        rule(
          'Obey `shadcn/no-raw-colors`, import `storybook/test`, clone `owner/repo`, title `Pages/Contact`.\n'
        ),
        'rules.dead-path'
      )
    ).toEqual([]);
  });

  test('matches the first folder by its exact case', () => {
    expect(
      findingsOf(
        {
          files: {
            '.claude/rules/example.md': 'Title it `Pages/Contact`.\n',
            'CLAUDE.md': 'Root.\n',
            'pages/index.md': 'Index.\n',
          },
          git: true,
        },
        'rules.dead-path'
      )
    ).toEqual([]);
  });

  test('is dead once its first folder exists', () => {
    expect(
      findingsOf(
        {
          files: {
            '.claude/rules/example.md': 'See `docs/gone.md`.\n',
            'CLAUDE.md': 'Root.\n',
            'docs/other.md': 'Other.\n',
          },
          git: true,
        },
        'rules.dead-path'
      )
    ).toHaveLength(1);
  });

  test('is still dead as a markdown link', () => {
    expect(
      findingsOf(rule('See [it](gone/guide.md).\n'), 'rules.dead-path')
    ).toHaveLength(1);
  });
});

describe('an extensionless import specifier', () => {
  test('resolves to the source file it names', () => {
    expect(findingsOf(specifier('database'), 'rules.dead-path')).toEqual([]);
  });

  test('is dead when no source file carries the name', () => {
    expect(findingsOf(specifier('gone'), 'rules.dead-path')).toHaveLength(1);
  });
});

describe('skill link resolution', () => {
  const skillProject = (
    body: string,
    extra: Record<string, string> = {}
  ): FixtureProject => ({
    files: {
      '.claude/skills/example/SKILL.md': skill(body),
      'CLAUDE.md': 'Root.\n',
      ...extra,
    },
    git: true,
  });
  const typescriptSkill = {
    '.claude/skills/typescript/references/zod.md': 'Zod.\n',
    '.claude/skills/typescript/SKILL.md': skill('See `references/zod.md`.\n'),
  };

  test('ignores markdown link syntax written as inline code', () => {
    expect(
      findingsOf(
        skillProject('Links are written as `[text](url)`.\n'),
        'authoring.reference.link.resolves'
      )
    ).toEqual([]);
  });

  test("resolves a reference qualified by another skill's name against that skill", () => {
    expect(
      findingsOf(
        skillProject(
          "Read the typescript skill's `references/zod.md`.\n",
          typescriptSkill
        ),
        'authoring.reference.link.resolves'
      )
    ).toEqual([]);
  });

  test('reports a qualified reference the named skill does not have', () => {
    expect(
      findingsOf(
        skillProject(
          "Read the typescript skill's `references/gone.md`.\n",
          typescriptSkill
        ),
        'authoring.reference.link.resolves'
      )
    ).toHaveLength(1);
  });

  test('does not report a backticked path whose first folder exists nowhere', () => {
    expect(
      findingsOf(
        skillProject('The site build runs `scripts/check-titles.mjs`.\n'),
        'authoring.reference.link.resolves'
      )
    ).toEqual([]);
  });

  test('reports it once that folder exists in the skill', () => {
    expect(
      findingsOf(
        skillProject('Run `scripts/check-titles.mjs`.\n', {
          '.claude/skills/example/scripts/other.sh': '#!/bin/sh\n',
        }),
        'authoring.reference.link.resolves'
      )
    ).toHaveLength(1);
  });
});
