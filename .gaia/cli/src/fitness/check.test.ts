import {afterEach, describe, expect, test} from 'vitest';
import {mkdirSync, readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {exitCodeFor, matchesSelector, runCheck} from './check.js';
import {FITNESS_CONFIG_RULES} from './rules/fitness-config.js';
import {
  createScratchProject,
  expectFixtureParity,
  runFitness,
} from './test-support.js';
import type {
  CheckReport,
  FixtureMap,
  FixtureProject,
  RuleDefinition,
} from './types.js';

const cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

const scratch = (project: FixtureProject) => {
  const created = createScratchProject(project);

  cleanups.push(created.cleanup);

  return created;
};

const checkReport = async (
  root: string,
  env: Record<string, string>,
  ...extra: string[]
): Promise<CheckReport> => {
  const result = await runFitness(['check', '--root', root, ...extra], {env});

  return result.json as CheckReport;
};

const exitReport = (severity: 'error' | 'info' | 'warning'): CheckReport => ({
  categories: [],
  findings: [
    {
      category: 'rules',
      file: 'f',
      fixable: false,
      line: 1,
      message: 'm',
      ownership: 'adopter',
      remediation: 'r',
      rule_id: 'rules.example.thing',
      severity,
    },
  ],
  inventory: [],
  overall: 'A+',
  scope: 'adopter',
  suppressed: [],
  upstream: [],
});

const claudeMdOwnership = (report: CheckReport) =>
  report.inventory.find((entry) => entry.path === 'CLAUDE.md')?.ownership;

const basicProject = (): FixtureProject => ({
  files: {
    '.claude/rules/example.md': '# Example\n',
    'CLAUDE.md': '# Project\n',
  },
  git: true,
});

describe('gaia fitness check', () => {
  test.each([
    [['--bogus'], 2],
    [['--fail-on', 'bogus'], 2],
    [['--scope', 'everything'], 2],
    [['--enforce', 'nope'], 2],
    [['--only', 'nope.at.all'], 2],
    [['--only', 'memory.dead-path'], 2],
    [['--enforce', 'memory.dead-path'], 2],
    [['--root'], 2],
  ])('%j exits %i', async (argv, expected) => {
    const {env, root} = scratch(basicProject());
    const result = await runFitness(['check', '--root', root, ...argv], {env});

    expect(result.exitCode).toBe(expected);
  });

  test('a root that is not a directory exits 3', async () => {
    const {root} = scratch(basicProject());
    const result = await runFitness([
      'check',
      '--root',
      path.join(root, 'CLAUDE.md'),
    ]);

    expect(result.exitCode).toBe(EXIT_CODES.COULD_NOT_RUN);
    expect(result.stderr).toContain('could_not_run');
  });

  test('a root that does not exist exits 3', async () => {
    const result = await runFitness([
      'check',
      '--root',
      path.join(tmpdir(), 'gaia-fitness-no-such-root'),
    ]);

    expect(result.exitCode).toBe(EXIT_CODES.COULD_NOT_RUN);
  });

  test('prints the seven top-level keys in contract order', async () => {
    const {env, root} = scratch(basicProject());
    const result = await runFitness(['check', '--json', '--root', root], {env});

    expect(result.exitCode).toBe(0);
    expect(Object.keys(result.json as object)).toEqual([
      'scope',
      'categories',
      'overall',
      'findings',
      'upstream',
      'suppressed',
      'inventory',
    ]);
    expect(
      (result.json as CheckReport).categories.map((category) => category.name)
    ).toEqual([
      'authoring',
      'claudemd',
      'frontmatter',
      'hooks',
      'prompt',
      'rules',
      'settings',
      'wiki',
    ]);
  });

  test('two runs on an unchanged project print byte-identical stdout, free of the root and HOME', async () => {
    const {env, root} = scratch(basicProject());
    const first = await runFitness(['check', '--root', root], {env});
    const second = await runFitness(['check', '--root', root], {env});

    expect(first.stdout).toBe(second.stdout);
    expect(first.stdout).not.toContain(root);

    expect(first.stdout).not.toContain(
      `${process.env.HOME ?? '/no-such-home'}/`
    );
  });

  test('grades categories with no applicable input n/a and claudemd always', async () => {
    const {env, root} = scratch(basicProject());
    const report = await checkReport(root, env);
    const grades = Object.fromEntries(
      report.categories.map((category) => [category.name, category.grade])
    );

    expect(grades.claudemd).toBe('A+');
    expect(grades.rules).toBe('A+');
    expect(grades.hooks).toBe('n/a');
    expect(grades.wiki).toBe('n/a');
    expect(report.overall).toBe('A+');
  });

  test('--only settings.fitness-config makes every other category n/a', async () => {
    const project = basicProject();

    project.files['.claude/settings.json'] = '{}\n';

    const {env, root} = scratch(project);
    const report = await checkReport(
      root,
      env,
      '--only',
      'settings.fitness-config'
    );
    const graded = report.categories.filter(
      (category) => category.grade !== 'n/a'
    );

    expect(graded.map((category) => category.name)).toEqual(['settings']);
  });

  test('gaia-shipped findings go to upstream under scope adopter and are graded under scope all', () => {
    const rule: RuleDefinition = {
      appliesTo: ['rule'],
      category: 'rules',
      check: (context) =>
        context.filesOfKind('rule').map((file) => ({
          file: file.path,
          line: 1,
          message: 'm',
          remediation: 'r',
        })),
      detection: 'test only',
      ruleId: 'rules.throwaway-example',
      severity: 'error',
    };
    const {env, root} = scratch({
      classifier: 'repo',
      files: {'.claude/rules/shipped.md': '# s\n'},
      git: true,
      manifest: {files: {'.claude/rules/shipped.md': 'owned'}},
    });
    const adopter = runCheck({catalog: [rule], env, root, scope: 'adopter'});
    const all = runCheck({catalog: [rule], env, root, scope: 'all'});

    expect(adopter.findings).toEqual([]);
    expect(adopter.upstream).toHaveLength(1);
    expect(adopter.upstream[0]?.remediation).toContain('/update-gaia');
    expect(adopter.categories.find((c) => c.name === 'rules')?.grade).toBe(
      'A+'
    );
    expect(all.findings).toHaveLength(1);
    expect(all.findings[0]?.ownership).toBe('gaia-shipped');
    expect(all.findings[0]?.fixable).toBe(false);
  });

  test('a rule that throws surfaces as exit 3, not a silent pass', () => {
    const rule: RuleDefinition = {
      appliesTo: ['all'],
      category: 'rules',
      check: () => {
        throw new Error('boom');
      },
      detection: 'test only',
      ruleId: 'rules.throws',
      severity: 'error',
    };
    const {env, root} = scratch(basicProject());

    expect(() =>
      runCheck({catalog: [rule], env, root, scope: 'adopter'})
    ).toThrow('boom');
  });
});

describe('exitCodeFor', () => {
  test('--fail-on error ignores warnings and infos', () => {
    expect(exitCodeFor(exitReport('warning'), 'error', [])).toBe(0);
    expect(exitCodeFor(exitReport('info'), 'error', [])).toBe(0);
    expect(exitCodeFor(exitReport('error'), 'error', [])).toBe(1);
  });

  test('--fail-on warning and info lower the bar', () => {
    expect(exitCodeFor(exitReport('warning'), 'warning', [])).toBe(1);
    expect(exitCodeFor(exitReport('info'), 'warning', [])).toBe(0);
    expect(exitCodeFor(exitReport('info'), 'info', [])).toBe(1);
  });

  test('--enforce fails on a matching warning but not a matching info', () => {
    expect(exitCodeFor(exitReport('warning'), 'error', ['rules.example'])).toBe(
      1
    );
    expect(exitCodeFor(exitReport('warning'), 'error', ['rules.other'])).toBe(
      0
    );
    expect(exitCodeFor(exitReport('info'), 'error', ['rules.example'])).toBe(0);
  });

  test('a selector is an exact id or a dotted prefix, not a substring', () => {
    expect(matchesSelector('rules.example', 'rules.example.thing')).toBe(true);
    expect(matchesSelector('rules.example.thing', 'rules.example.thing')).toBe(
      true
    );
    expect(matchesSelector('rules.exam', 'rules.example.thing')).toBe(false);
  });
});

describe('gaia fitness rules', () => {
  test('lists the catalog and the inventory-only rule, sorted, byte-identical across runs', async () => {
    const first = await runFitness(['rules', '--json']);
    const second = await runFitness(['rules']);
    const rules = first.json as {
      inventory_only?: true;
      rule_id: string;
    }[];

    expect(first.exitCode).toBe(0);
    expect(first.stdout).toBe(second.stdout);
    expect(rules.map((rule) => rule.rule_id)).toEqual(
      rules.map((rule) => rule.rule_id).toSorted((a, b) => a.localeCompare(b))
    );
    expect(
      rules.find((rule) => rule.rule_id === 'memory.dead-path')
    ).toMatchObject({inventory_only: true});
    expect(
      rules.filter((rule) => rule.inventory_only === true).map((r) => r.rule_id)
    ).toEqual(['memory.dead-path']);
  });

  test('an unknown argument exits 2', async () => {
    const result = await runFitness(['rules', '--xml']);

    expect(result.exitCode).toBe(2);
  });
});

describe('test-support', () => {
  test('settingsJson wins over a files entry for .claude/settings.json', async () => {
    const {root} = scratch({
      files: {'.claude/settings.json': '{"model":"haiku"}'},
      git: true,
      settingsJson: {model: 'opus'},
    });
    expect(
      JSON.parse(readFileSync(path.join(root, '.claude/settings.json'), 'utf8'))
    ).toEqual({model: 'opus'});
  });

  test('git: true makes every file tracked, so a depth-3 file is discovered', async () => {
    const {env, root} = scratch({
      files: {'x/y/CLAUDE.md': '# x\n'},
      git: true,
    });
    const report = await checkReport(root, env);

    expect(report.inventory.map((entry) => entry.path)).toContain(
      'x/y/CLAUDE.md'
    );
  });

  test("classifier 'repo' with git classifies an unlisted path adopter; 'none' classifies it unknown", async () => {
    const owned = scratch({
      classifier: 'repo',
      files: {'CLAUDE.md': '# x\n'},
      git: true,
    });
    const unowned = scratch({
      classifier: 'none',
      files: {'CLAUDE.md': '# x\n'},
      git: true,
    });
    const ownedReport = await checkReport(owned.root, owned.env);
    const unownedReport = await checkReport(unowned.root, unowned.env);
    expect(claudeMdOwnership(ownedReport)).toBe('adopter');
    expect(claudeMdOwnership(unownedReport)).toBe('unknown');
  });

  test('a manifest owned entry classifies gaia-shipped', async () => {
    const project = scratch({
      files: {'.claude/rules/shipped.md': '# s\n'},
      git: true,
      manifest: {files: {'.claude/rules/shipped.md': 'owned'}},
    });
    const report = await checkReport(project.root, project.env);

    expect(
      report.inventory.find(
        (entry) => entry.path === '.claude/rules/shipped.md'
      )?.ownership
    ).toBe('gaia-shipped');
  });

  test('a vendor pin classifies its target third-party', async () => {
    const project = scratch({
      files: {'vendored/CLAUDE.md': '# v\n'},
      git: true,
      vendorPins: {example: 'vendored'},
    });
    const report = await checkReport(project.root, project.env);

    expect(
      report.inventory.find((entry) => entry.path === 'vendored/CLAUDE.md')
        ?.ownership
    ).toBe('third-party');
  });

  test('cleanup removes the scratch directory', () => {
    const created = createScratchProject(basicProject());

    created.cleanup();

    expect(() => mkdirSync(path.join(created.root, 'x'))).toThrow(/ENOENT/);
  });
});

describe('expectFixtureParity sensitivity', () => {
  const rule = FITNESS_CONFIG_RULES.find(
    (candidate) => candidate.ruleId === 'settings.fitness-config.parse'
  ) as RuleDefinition;
  const goodFixtures: FixtureMap = {
    [rule.ruleId]: {
      green: () => ({
        files: {'.claude/gaia-fitness.json': '{"version":1,"ignore":[]}'},
        git: true,
      }),
      red: () => ({
        files: {'.claude/gaia-fitness.json': '{ not json'},
        git: true,
      }),
    },
  };

  test('passes for a matching pair', () => {
    expect(() => {
      expectFixtureParity([rule], goodFixtures);
    }).not.toThrow();
  });

  test('fails when a rule has no fixture entry', () => {
    expect(() => {
      expectFixtureParity([rule], {});
    }).toThrow(/no fixture pair/);
  });

  test('fails when a fixture names no rule', () => {
    expect(() => {
      expectFixtureParity([], goodFixtures);
    }).toThrow(/fixtures with no rule/);
  });

  test('fails when the red fixture yields no finding', () => {
    expect(() => {
      expectFixtureParity([rule], {
        [rule.ruleId]: {
          green: goodFixtures[rule.ruleId]!.green,
          red: goodFixtures[rule.ruleId]!.green,
        },
      });
    }).toThrow(/fires on its red fixture/);
  });

  test('fails when the green fixture still fires the rule', () => {
    expect(() => {
      expectFixtureParity([rule], {
        [rule.ruleId]: {
          green: goodFixtures[rule.ruleId]!.red,
          red: goodFixtures[rule.ruleId]!.red,
        },
      });
    }).toThrow(/stays quiet on its green fixture/);
  });
});
