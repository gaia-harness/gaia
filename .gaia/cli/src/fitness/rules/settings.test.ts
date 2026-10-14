import {describe, expect, test} from 'vitest';
import {runCheck} from '../check.js';
import {
  createScratchProject,
  expectFixtureParity,
  FIXTURE_PARITY_TIMEOUT_MS,
  runFitness,
} from '../test-support.js';
import type {CheckReport, FixtureProject} from '../types.js';
import {
  buildCredentialValue,
  RED_LOCAL_SETTINGS,
  SETTINGS_FIXTURES,
} from './settings.fixtures.js';
import {SETTINGS_RULES} from './settings.js';

const reportFor = (project: FixtureProject): CheckReport => {
  const scratch = createScratchProject(project);

  try {
    return runCheck({
      catalog: SETTINGS_RULES,
      env: scratch.env,
      root: scratch.root,
      scope: 'all',
    });
  } finally {
    scratch.cleanup();
  }
};

const idsFor = (project: FixtureProject): string[] =>
  reportFor(project).findings.map((finding) => finding.rule_id);

const permissionsProject = (allow: unknown[]): FixtureProject => ({
  files: {},
  git: true,
  settingsJson: {permissions: {allow}},
});

describe('settings rules fixtures', () => {
  test(
    'fires on every red fixture and stays quiet on every green one',
    () => {
      expectFixtureParity(SETTINGS_RULES, SETTINGS_FIXTURES);
    },
    FIXTURE_PARITY_TIMEOUT_MS
  );
});

describe('settings.valid-json', () => {
  test('reports an unparseable settings file and grades the category F', () => {
    const report = reportFor({
      files: {'.claude/settings.json': '{ "env": '},
      git: true,
    });

    expect(report.findings.map((finding) => finding.rule_id)).toEqual([
      'settings.valid-json',
    ]);
    expect(
      report.categories.find((category) => category.name === 'settings')?.grade
    ).toBe('F');
  });

  test('reports a nested settings file', () => {
    expect(
      idsFor({files: {'frontend/.claude/settings.json': '{,}'}, git: true})
    ).toEqual(['settings.valid-json']);
  });

  test('passes a parseable file', () => {
    expect(
      idsFor({files: {'.claude/settings.json': '{}\n'}, git: true})
    ).toEqual([]);
  });
});

describe('settings.env-secrets', () => {
  test('names the key and never echoes the value', async () => {
    const value = buildCredentialValue();
    const scratch = createScratchProject({
      files: {},
      git: true,
      settingsJson: {env: {EXAMPLE_SETTING: value}},
    });

    try {
      const run = await runFitness(
        ['check', '--root', scratch.root, '--scope', 'all'],
        {env: scratch.env}
      );
      const output = `${run.stdout}${run.stderr}`;
      const finding = (run.json as CheckReport).findings.find(
        (candidate) => candidate.rule_id === 'settings.env-secrets'
      );

      expect(finding?.message).toContain('EXAMPLE_SETTING');

      for (let start = 0; start + 8 <= value.length; start += 1) {
        expect(output).not.toContain(value.slice(start, start + 8));
      }
    } finally {
      scratch.cleanup();
    }
  });

  test('reports a secret-shaped key with a non-empty value', () => {
    expect(
      idsFor({
        files: {},
        git: true,
        settingsJson: {env: {SERVICE_API_KEY: 'abc'}},
      })
    ).toEqual(['settings.env-secrets']);
  });

  test('passes an empty value under a secret-shaped key', () => {
    expect(
      idsFor({
        files: {},
        git: true,
        settingsJson: {env: {SERVICE_API_KEY: ''}},
      })
    ).toEqual([]);
  });

  test('passes an ordinary value', () => {
    expect(
      idsFor({
        files: {},
        git: true,
        settingsJson: {env: {EXAMPLE_MODE: 'strict'}},
      })
    ).toEqual([]);
  });

  test('leaves the machine-local file alone', () => {
    expect(
      idsFor({
        files: {
          '.claude/settings.local.json': JSON.stringify({
            env: {SERVICE_API_KEY: 'abc'},
          }),
          '.gitignore': '.claude/settings.local.json\n',
        },
        git: true,
      })
    ).toEqual([]);
  });
});

describe('settings.redundant-permissions', () => {
  test.each([
    ['an exact duplicate', ['Read', 'Read']],
    ['a Tool(spec) shadowed by bare Tool', ['Bash', 'Bash(ls)']],
    ['a bare Tool listed after its Tool(spec)', ['Bash(ls)', 'Bash']],
    ['a Bash prefix shadowed by prefix:*', ['Bash(git:*)', 'Bash(git status)']],
    [
      'a Bash prefix shadowed by an earlier-listed prefix:*',
      ['Bash(git status)', 'Bash(git:*)'],
    ],
  ])('reports %s once', (_label, allow) => {
    expect(idsFor(permissionsProject(allow))).toEqual([
      'settings.redundant-permissions',
    ]);
  });

  test.each([
    ['unrelated tools', ['Read', 'Edit']],
    ['sibling Bash specs', ['Bash(ls)', 'Bash(pwd)']],
    ['a longer prefix that only shares letters', ['Bash(git:*)', 'Bash(gitk)']],
    ['a lone prefix:*', ['Bash(git:*)']],
  ])('passes %s', (_label, allow) => {
    expect(idsFor(permissionsProject(allow))).toEqual([]);
  });

  test('does not compare entries across lists', () => {
    expect(
      idsFor({
        files: {},
        git: true,
        settingsJson: {permissions: {allow: ['Bash'], deny: ['Bash(rm:*)']}},
      })
    ).toEqual([]);
  });

  test('points at the later occurrence of a duplicate', () => {
    const finding = reportFor({
      files: {
        '.claude/settings.json':
          '{\n  "permissions": {\n    "allow": [\n      "Read",\n      "Read"\n    ]\n  }\n}\n',
      },
      git: true,
    }).findings[0];

    expect(finding?.line).toBe(5);
  });
});

describe('settings.local-gitignored', () => {
  test('reports an unignored local settings file', () => {
    expect(idsFor(RED_LOCAL_SETTINGS)).toEqual(['settings.local-gitignored']);
  });

  test('passes an ignored one', () => {
    expect(
      idsFor({
        files: {
          '.claude/settings.local.json': '{}\n',
          '.gitignore': '.claude/settings.local.json\n',
        },
        git: true,
      })
    ).toEqual([]);
  });

  test('stays quiet outside a git repository', () => {
    expect(idsFor({files: {'.claude/settings.local.json': '{}\n'}})).toEqual(
      []
    );
  });
});
