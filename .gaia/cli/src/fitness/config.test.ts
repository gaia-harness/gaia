import {afterEach, describe, expect, test} from 'vitest';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {exitCodeFor, runCheck} from './check.js';
import {
  appliedEntries,
  applySuppressions,
  canonicalRuleIds,
  interpretConfig,
} from './config.js';
import {FITNESS_CONFIG_RULES} from './rules/fitness-config.js';
import {createScratchProject} from './test-support.js';
import type {Finding, FixtureProject, RuleDefinition} from './types.js';

const THROWAWAY_ID = 'rules.throwaway-example';

/** A stand-in rule: one warning on every rule file, so suppression has something to move. */
const throwawayRule: RuleDefinition = {
  aliases: ['rules.retired-example'],
  appliesTo: ['rule'],
  category: 'rules',
  check: (context) =>
    context.filesOfKind('rule').map((file) => ({
      file: file.path,
      line: 1,
      message: 'throwaway',
      remediation: 'none',
    })),
  detection: 'test only',
  ruleId: THROWAWAY_ID,
  severity: 'warning',
};

const catalog = [throwawayRule, ...FITNESS_CONFIG_RULES];

const cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

const scratch = (project: FixtureProject) => {
  const created = createScratchProject(project);

  cleanups.push(created.cleanup);

  return created;
};

/** Writes a config file outside any project root and returns its path. */
const external = (text: string): string => {
  const directory = mkdtempSync(path.join(tmpdir(), 'gaia-config-'));

  cleanups.push(() => {
    rmSync(directory, {force: true, recursive: true});
  });

  const file = path.join(directory, 'custom.json');

  writeFileSync(file, text);

  return file;
};

const entry = (overrides: Record<string, unknown> = {}) => ({
  path: '.claude/rules/a.md',
  reason: 'accepted on purpose',
  rule_id: THROWAWAY_ID,
  ...overrides,
});

const projectWithConfig = (config: string): FixtureProject => ({
  files: {
    '.claude/gaia-fitness.json': config,
    '.claude/rules/a.md': '# a\n',
    '.claude/rules/b.md': '# b\n',
    '.claude/rules/c.md': '# c\n',
  },
  git: true,
});

const ids = (findings: readonly Finding[]): string[] =>
  findings.map((finding) => `${finding.rule_id}@${finding.file}`);

describe('suppressions', () => {
  test('move only the listed path to suppressed and flag the three bad entries', () => {
    const {env, root} = scratch(
      projectWithConfig(
        JSON.stringify({
          ignore: [
            entry(),
            entry({path: '.claude/rules/c.md', reason: ''}),
            entry({reason: 'unknown rule', rule_id: 'rules.no-such-rule'}),
            entry({path: '.claude/rules/gone.md'}),
          ],
          version: 1,
        })
      )
    );
    const report = runCheck({catalog, env, root, scope: 'adopter'});

    expect(report.suppressed).toHaveLength(1);
    expect(report.suppressed[0]).toMatchObject({
      file: '.claude/rules/a.md',
      reason: 'accepted on purpose',
      rule_id: THROWAWAY_ID,
    });
    expect(ids(report.findings)).toEqual(
      expect.arrayContaining([
        `${THROWAWAY_ID}@.claude/rules/b.md`,
        `${THROWAWAY_ID}@.claude/rules/c.md`,
      ])
    );
    expect(ids(report.findings)).not.toContain(
      `${THROWAWAY_ID}@.claude/rules/a.md`
    );

    const configFindings = report.findings
      .filter((finding) =>
        finding.rule_id.startsWith('settings.fitness-config.')
      )
      .map((finding) => finding.rule_id);

    expect(configFindings.toSorted((a, b) => a.localeCompare(b))).toEqual([
      'settings.fitness-config.no-reason',
      'settings.fitness-config.stale',
      'settings.fitness-config.stale',
    ]);
  });

  test('a retired alias suppresses the rule it answers to', () => {
    const {env, root} = scratch(
      projectWithConfig(
        JSON.stringify({
          ignore: [entry({rule_id: 'rules.retired-example'})],
          version: 1,
        })
      )
    );
    const report = runCheck({catalog, env, root, scope: 'adopter'});

    expect(report.suppressed.map((finding) => finding.file)).toEqual([
      '.claude/rules/a.md',
    ]);
  });

  test('a settings.fitness-config finding is never suppressible', () => {
    const {env, root} = scratch(
      projectWithConfig(
        JSON.stringify({
          ignore: [
            entry({path: '.claude/rules/c.md', reason: ''}),
            entry({
              path: '.claude/gaia-fitness.json',
              rule_id: 'settings.fitness-config.no-reason',
            }),
          ],
          version: 1,
        })
      )
    );
    const report = runCheck({catalog, env, root, scope: 'adopter'});

    expect(report.suppressed.map((finding) => finding.rule_id)).not.toContain(
      'settings.fitness-config.no-reason'
    );
    expect(
      report.findings.some(
        (finding) => finding.rule_id === 'settings.fitness-config.no-reason'
      )
    ).toBe(true);
  });

  test.each([
    ['unparseable JSON', '{ not json'],
    ['a version other than 1', JSON.stringify({ignore: [entry()], version: 2})],
  ])('%s yields one parse error, no suppression and exit 1', (_name, text) => {
    const {env, root} = scratch(projectWithConfig(text));
    const report = runCheck({catalog, env, root, scope: 'adopter'});
    const parseErrors = report.findings.filter(
      (finding) => finding.rule_id === 'settings.fitness-config.parse'
    );

    expect(parseErrors).toHaveLength(1);
    expect(parseErrors[0]).toMatchObject({
      file: '.claude/gaia-fitness.json',
      severity: 'error',
    });
    expect(report.suppressed).toEqual([]);
    expect(
      report.findings.filter((finding) => finding.rule_id === THROWAWAY_ID)
    ).toHaveLength(3);
    expect(exitCodeFor(report, 'error', [])).toBe(1);
  });
});

describe('--config', () => {
  test('a path that does not exist means no suppressions and no config finding', () => {
    const {env, root} = scratch(projectWithConfig('{"version":1,"ignore":[]}'));
    const report = runCheck({
      catalog,
      configPath: path.join(root, 'does-not-exist.json'),
      env,
      root,
      scope: 'adopter',
    });

    expect(report.suppressed).toEqual([]);
    expect(
      report.findings.filter((finding) =>
        finding.rule_id.startsWith('settings.fitness-config.')
      )
    ).toEqual([]);
  });

  test('an unparseable file outside the root is one parse error named <config>, with no absolute path', () => {
    const {env, root} = scratch(projectWithConfig('{"version":1,"ignore":[]}'));
    const configPath = external('{ not json');
    const report = runCheck({catalog, configPath, env, root, scope: 'adopter'});
    const parseErrors = report.findings.filter(
      (finding) => finding.rule_id === 'settings.fitness-config.parse'
    );

    expect(parseErrors).toHaveLength(1);
    expect(parseErrors[0]).toMatchObject({file: '<config>', line: 0});

    const printed = JSON.stringify(report);

    expect(printed).not.toContain(path.dirname(configPath));
    expect(printed).not.toContain(root);
  });

  test('a valid --config applies while a broken discovered file still reports its own error', () => {
    const {env, root} = scratch(projectWithConfig('{ not json'));
    const configPath = external(
      JSON.stringify({ignore: [entry()], version: 1})
    );
    const report = runCheck({catalog, configPath, env, root, scope: 'adopter'});

    expect(report.suppressed.map((finding) => finding.file)).toEqual([
      '.claude/rules/a.md',
    ]);

    const parseErrors = report.findings.filter(
      (finding) => finding.rule_id === 'settings.fitness-config.parse'
    );

    expect(parseErrors).toHaveLength(1);
    expect(parseErrors[0]?.file).toBe('.claude/gaia-fitness.json');
  });

  test('--config naming the discovered file reports only the discovered-file findings', () => {
    const {env, root} = scratch(projectWithConfig('{ not json'));
    const report = runCheck({
      catalog,
      configPath: path.join(root, '.claude/gaia-fitness.json'),
      env,
      root,
      scope: 'adopter',
    });

    expect(
      report.findings.filter(
        (finding) => finding.rule_id === 'settings.fitness-config.parse'
      )
    ).toHaveLength(1);
  });
});

describe('config helpers', () => {
  test('interpretConfig rejects non-objects, a wrong version and a non-list ignore', () => {
    expect(interpretConfig(null).ok).toBe(false);
    expect(interpretConfig([]).ok).toBe(false);
    expect(interpretConfig({version: 2}).ok).toBe(false);
    expect(interpretConfig({ignore: 'x', version: 1}).ok).toBe(false);
    expect(interpretConfig({version: 1})).toEqual({entries: [], ok: true});
  });

  test('appliedEntries drops entries missing a field or a reason', () => {
    expect(
      appliedEntries([
        entry(),
        entry({reason: ' '.repeat(3)}),
        entry({reason: undefined}),
        {path: 'x'},
        'text',
      ])
    ).toHaveLength(1);
  });

  test('applySuppressions never moves a config-rule finding', () => {
    const finding: Finding = {
      category: 'settings',
      file: 'f',
      fixable: false,
      line: 1,
      message: 'm',
      ownership: 'adopter',
      remediation: 'r',
      rule_id: 'settings.fitness-config.stale',
      severity: 'warning',
    };
    const result = applySuppressions(
      [finding],
      [{path: 'f', reason: 'why', ruleId: 'settings.fitness-config.stale'}],
      canonicalRuleIds(catalog)
    );

    expect(result.suppressed).toEqual([]);
    expect(result.kept).toEqual([finding]);
  });
});
