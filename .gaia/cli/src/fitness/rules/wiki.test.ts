import {describe, expect, test} from 'vitest';
import {spawnSync} from 'node:child_process';
import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {runCheck} from '../check.js';
import {
  createScratchProject,
  expectFixtureParity,
  runFitness,
} from '../test-support.js';
import type {CheckReport, FixtureProject} from '../types.js';
import {registryFiles, WIKI_FIXTURES} from './wiki.fixtures.js';
import {WIKI_RULES} from './wiki.js';

const wikiFindings = (
  project: FixtureProject,
  ruleId: string
): CheckReport['findings'] => {
  const scratch = createScratchProject(project);

  try {
    const report = runCheck({
      env: scratch.env,
      root: scratch.root,
      scope: 'all',
    });

    return report.findings.filter((finding) => finding.rule_id === ruleId);
  } finally {
    scratch.cleanup();
  }
};

const citing = (reference: string): string =>
  `# Example Page\n\nSee \`${reference}\` for the details.\n`;

describe('wiki rules', () => {
  test('every rule has a red fixture that fires it and a green fixture that does not', () => {
    expectFixtureParity(WIKI_RULES, WIKI_FIXTURES);
  });

  test('a dead reference names the page, the line and the missing path', () => {
    const findings = wikiFindings(
      WIKI_FIXTURES['wiki.dead-paths']?.red() ?? {files: {}},
      'wiki.dead-paths'
    );

    expect(findings).toHaveLength(1);
    expect(findings[0]).toMatchObject({
      file: 'wiki/concepts/Example Page.md',
      line: 3,
    });
    expect(findings[0]?.message).toContain('.claude/hooks/missing.sh');
  });

  test('a project with no wiki directory yields no wiki finding', () => {
    const scratch = createScratchProject({
      files: {'CLAUDE.md': '# Project\n'},
      git: true,
    });

    try {
      const report = runCheck({
        env: scratch.env,
        root: scratch.root,
        scope: 'all',
      });

      expect(
        report.findings.filter((finding) => finding.category === 'wiki')
      ).toEqual([]);
      expect(
        report.categories.find((category) => category.name === 'wiki')?.grade
      ).toBe('n/a');
    } finally {
      scratch.cleanup();
    }
  });

  test('an unloadable package registry yields one finding and the check still runs', async () => {
    const scratch = createScratchProject({
      files: {
        '.gaia/packages.json': 'this is not json',
        'wiki/concepts/Example Page.md': citing('.claude/hooks/missing.sh'),
        'wiki/index.md': '# Index\n\n[[Example Page]]\n',
      },
      git: true,
    });

    try {
      const result = await runFitness(
        ['check', '--root', scratch.root, '--scope', 'all'],
        {env: scratch.env}
      );
      const report = result.json as CheckReport;
      const deadPaths = report.findings.filter(
        (finding) => finding.rule_id === 'wiki.dead-paths'
      );

      expect([0, 1]).toContain(result.exitCode);
      expect(deadPaths).toHaveLength(1);
      expect(deadPaths[0]).toMatchObject({file: 'wiki', line: 0});
      expect(deadPaths[0]?.message).toContain('gaia-packages');
      expect(report.categories).toHaveLength(8);
    } finally {
      scratch.cleanup();
    }
  });

  test('a dead reference in an untracked page yields no finding, the same reference in a tracked page yields one', () => {
    const project: FixtureProject = {
      files: {
        ...registryFiles(),
        'wiki/concepts/Tracked Page.md': citing('.claude/hooks/missing.sh'),
        'wiki/index.md': '# Index\n\n[[Tracked Page]]\n',
      },
      git: true,
    };
    const scratch = createScratchProject(project);

    try {
      const untrackedDirectory = path.join(scratch.root, 'wiki/concepts');

      mkdirSync(untrackedDirectory, {recursive: true});
      writeFileSync(
        path.join(untrackedDirectory, 'Untracked Page.md'),
        citing('.claude/hooks/missing.sh')
      );

      const tracked = spawnSync('git', ['ls-files', 'wiki'], {
        cwd: scratch.root,
        encoding: 'utf8',
      }).stdout;

      expect(tracked).not.toContain('Untracked Page.md');

      const report = runCheck({
        env: scratch.env,
        root: scratch.root,
        scope: 'all',
      });
      const files = report.findings
        .filter((finding) => finding.rule_id === 'wiki.dead-paths')
        .map((finding) => finding.file);

      expect(files).toEqual(['wiki/concepts/Tracked Page.md']);
    } finally {
      scratch.cleanup();
    }
  });

  test('an orphan page in an untracked file yields no orphan finding', () => {
    const scratch = createScratchProject({
      files: {
        ...registryFiles(),
        'wiki/concepts/Tracked Page.md': '# Tracked Page\n',
        'wiki/index.md': '# Index\n\n[[Tracked Page]]\n',
      },
      git: true,
    });

    try {
      writeFileSync(
        path.join(scratch.root, 'wiki/concepts/Loose Page.md'),
        '# Loose Page\n'
      );

      const report = runCheck({
        env: scratch.env,
        root: scratch.root,
        scope: 'all',
      });

      expect(
        report.findings.filter((finding) => finding.rule_id === 'wiki.orphans')
      ).toEqual([]);
    } finally {
      scratch.cleanup();
    }
  });
});
