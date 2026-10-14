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

const nestedClaudeMd = (withTarget: boolean): FixtureProject => ({
  files: {
    'CLAUDE.md': 'Root.\n',
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
  test('is found when any tracked file carries that name', () => {
    expect(findingsOf(bareName(true), 'rules.dead-path')).toEqual([]);
  });

  test('is dead when no tracked file carries that name', () => {
    expect(findingsOf(bareName(false), 'rules.dead-path')).toHaveLength(1);
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
