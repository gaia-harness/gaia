import {afterEach, describe, expect, test} from 'vitest';
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

type Severity = 'error' | 'info' | 'warning';

const exitReport = (severity: Severity): CheckReport => ({
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

  test.each<[string, () => string, string]>([
    [
      'a root that is not a directory exits 3',
      () => path.join(scratch(basicProject()).root, 'CLAUDE.md'),
      'could_not_run',
    ],
    [
      'a root that does not exist exits 3',
      () => path.join(tmpdir(), 'gaia-fitness-no-such-root'),
      '',
    ],
  ])('%s', async (_name, rootFor, stderrFragment) => {
    const result = await runFitness(['check', '--root', rootFor()]);

    expect(result.exitCode).toBe(EXIT_CODES.COULD_NOT_RUN);
    expect(result.stderr).toContain(stderrFragment);
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
  test.each<
    [
      string,
      'error' | 'info' | 'warning',
      'error' | 'info' | 'warning',
      string[],
      number,
    ]
  >([
    ['--fail-on error ignores a warning', 'warning', 'error', [], 0],
    ['--fail-on error ignores an info', 'info', 'error', [], 0],
    ['--fail-on error fails on an error', 'error', 'error', [], 1],
    ['--fail-on warning fails on a warning', 'warning', 'warning', [], 1],
    ['--fail-on warning ignores an info', 'info', 'warning', [], 0],
    ['--fail-on info fails on an info', 'info', 'info', [], 1],
    [
      '--enforce fails on a matching warning',
      'warning',
      'error',
      ['rules.example'],
      1,
    ],
    [
      '--enforce ignores a warning that does not match',
      'warning',
      'error',
      ['rules.other'],
      0,
    ],
    [
      '--enforce does not fail on a matching info',
      'info',
      'error',
      ['rules.example'],
      0,
    ],
  ])('%s', (_name, severity, failOn, enforce, expected) => {
    expect(exitCodeFor(exitReport(severity), failOn, enforce)).toBe(expected);
  });

  test.each<[string, string, boolean]>([
    ['a selector matches a dotted prefix', 'rules.example', true],
    ['a selector matches the exact id', 'rules.example.thing', true],
    ['a selector is not a substring', 'rules.exam', false],
  ])('%s', (_name, selector, expected) => {
    expect(matchesSelector(selector, 'rules.example.thing')).toBe(expected);
  });
});

describe('gaia fitness rules', () => {
  test('prints the same JSON with and without --json', async () => {
    const first = await runFitness(['rules', '--json']);
    const second = await runFitness(['rules']);

    expect(first.exitCode).toBe(0);
    expect(first.stdout).toBe(second.stdout);
  });

  test('an unknown argument exits 2', async () => {
    const result = await runFitness(['rules', '--xml']);

    expect(result.exitCode).toBe(2);
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

  test.each<[string, () => FixtureMap, RegExp, (typeof rule)[]]>([
    [
      'fails when a rule has no fixture entry',
      () => ({}),
      /no fixture pair/,
      [rule],
    ],
    [
      'fails when a fixture names no rule',
      () => goodFixtures,
      /fixtures with no rule/,
      [],
    ],
    [
      'fails when the red fixture yields no finding',
      () => ({
        [rule.ruleId]: {
          green: goodFixtures[rule.ruleId]!.green,
          red: goodFixtures[rule.ruleId]!.green,
        },
      }),
      /fires on its red fixture/,
      [rule],
    ],
    [
      'fails when the green fixture still fires the rule',
      () => ({
        [rule.ruleId]: {
          green: goodFixtures[rule.ruleId]!.red,
          red: goodFixtures[rule.ruleId]!.red,
        },
      }),
      /stays quiet on its green fixture/,
      [rule],
    ],
  ])('%s', (_name, fixtures, pattern, rules) => {
    expect(() => {
      expectFixtureParity(rules, fixtures());
    }).toThrow(pattern);
  });
});
