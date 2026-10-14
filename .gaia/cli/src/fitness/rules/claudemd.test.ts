import {afterEach, describe, expect, test} from 'vitest';
import {
  chmodSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  NESTED_CLAUDE_MD_WORD_BUDGET,
  ROOT_CLAUDE_MD_WORD_BUDGET,
  RULE_LINE_BUDGET,
} from '../budgets.js';
import {runCheck} from '../check.js';
import {
  createScratchProject,
  expectFixtureParity,
  FIXTURE_PARITY_TIMEOUT_MS,
  runFitness,
} from '../test-support.js';
import type {Finding, FixtureProject, RuleDefinition} from '../types.js';
import {CLAUDEMD_FIXTURES, wordsOf} from './claudemd.fixtures.js';
import {
  CLAUDEMD_RULES,
  createClaudemdRules,
  DEFAULT_BUDGETS,
} from './claudemd.js';

const cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

const findingsOf = (
  project: FixtureProject,
  ruleId: string,
  catalog: readonly RuleDefinition[] = CLAUDEMD_RULES
): readonly Finding[] => {
  const scratch = createScratchProject(project);

  cleanups.push(scratch.cleanup);

  return runCheck({
    catalog,
    env: scratch.env,
    root: scratch.root,
    scope: 'all',
  }).findings.filter((finding) => finding.rule_id === ruleId);
};

const linesOf = (count: number): string =>
  Array.from({length: count}, () => 'line\n').join('');

const ruleProject = (lines: number): FixtureProject => ({
  files: {
    '.claude/rules/example.md': linesOf(lines),
    'CLAUDE.md': 'Project rules.\n',
  },
  git: true,
});

describe('claudemd rules', () => {
  test(
    'every rule has a red fixture that fires it and a green fixture that does not',
    () => {
      expectFixtureParity(CLAUDEMD_RULES, CLAUDEMD_FIXTURES);
    },
    FIXTURE_PARITY_TIMEOUT_MS
  );

  test('the default budgets are the budgets module constants', () => {
    expect(DEFAULT_BUDGETS).toEqual({
      nestedWords: NESTED_CLAUDE_MD_WORD_BUDGET,
      rootWords: ROOT_CLAUDE_MD_WORD_BUDGET,
      ruleLines: RULE_LINE_BUDGET,
    });
  });
});

describe('claudemd.budget', () => {
  test('a root CLAUDE.md at the budget has no finding and one word over has one', () => {
    expect(
      findingsOf(
        {
          files: {'CLAUDE.md': wordsOf(ROOT_CLAUDE_MD_WORD_BUDGET)},
          git: true,
        },
        'claudemd.budget'
      )
    ).toEqual([]);

    const over = findingsOf(
      {
        files: {'CLAUDE.md': wordsOf(ROOT_CLAUDE_MD_WORD_BUDGET + 1)},
        git: true,
      },
      'claudemd.budget'
    );

    expect(over).toHaveLength(1);
    expect(over[0]?.file).toBe('CLAUDE.md');
    expect(over[0]?.message).toContain(String(ROOT_CLAUDE_MD_WORD_BUDGET + 1));
    expect(over[0]?.message).toContain(String(ROOT_CLAUDE_MD_WORD_BUDGET));
  });

  test('a nested CLAUDE.md is held to the nested budget, not the root one', () => {
    const files = {
      'CLAUDE.md': 'Project rules.\n',
      'frontend/CLAUDE.md': wordsOf(NESTED_CLAUDE_MD_WORD_BUDGET),
    };

    expect(findingsOf({files, git: true}, 'claudemd.budget')).toEqual([]);

    const over = findingsOf(
      {
        files: {
          ...files,
          'frontend/CLAUDE.md': wordsOf(NESTED_CLAUDE_MD_WORD_BUDGET + 50),
        },
        git: true,
      },
      'claudemd.budget'
    );

    expect(over.map((finding) => finding.file)).toEqual(['frontend/CLAUDE.md']);
  });

  test('a CLAUDE.md four path segments deep is not discovered, so it is not measured', () => {
    expect(
      findingsOf(
        {
          files: {
            'a/b/c/CLAUDE.md': wordsOf(900),
            'CLAUDE.md': 'Project rules.\n',
          },
          git: true,
        },
        'claudemd.budget'
      )
    ).toEqual([]);
  });

  test('a rule file at the line budget has no finding and one line over has one', () => {
    expect(
      findingsOf(ruleProject(RULE_LINE_BUDGET), 'claudemd.budget')
    ).toEqual([]);
    expect(
      findingsOf(ruleProject(RULE_LINE_BUDGET + 1), 'claudemd.budget').map(
        (finding) => finding.file
      )
    ).toEqual(['.claude/rules/example.md']);
  });

  test('the rule reads its budgets from the injected values, so moving a budget moves the findings', () => {
    const project: FixtureProject = {
      files: {
        '.claude/rules/example.md': linesOf(3),
        'CLAUDE.md': wordsOf(20),
        'frontend/CLAUDE.md': wordsOf(20),
      },
      git: true,
    };

    expect(findingsOf(project, 'claudemd.budget')).toEqual([]);

    const tightened = createClaudemdRules({
      nestedWords: 5,
      rootWords: 5,
      ruleLines: 2,
    });

    expect(
      findingsOf(project, 'claudemd.budget', tightened).map(
        (finding) => finding.file
      )
    ).toEqual(['.claude/rules/example.md', 'CLAUDE.md', 'frontend/CLAUDE.md']);
  });
});

describe('claudemd.missing-root', () => {
  test('a project without a root CLAUDE.md gets one finding at line 0 and an F category', () => {
    const scratch = createScratchProject({
      files: {'README.md': '# Project\n'},
      git: true,
    });

    cleanups.push(scratch.cleanup);

    const report = runCheck({
      catalog: CLAUDEMD_RULES,
      env: scratch.env,
      root: scratch.root,
      scope: 'all',
    });
    const missing = report.findings.filter(
      (finding) => finding.rule_id === 'claudemd.missing-root'
    );

    expect(missing).toHaveLength(1);
    expect(missing[0]).toMatchObject({file: 'CLAUDE.md', line: 0});
    expect(
      report.categories.find((entry) => entry.name === 'claudemd')?.grade
    ).toBe('F');
  });

  test('a nested CLAUDE.md does not stand in for the root one', () => {
    expect(
      findingsOf(
        {files: {'frontend/CLAUDE.md': 'Nested rules.\n'}, git: true},
        'claudemd.missing-root'
      )
    ).toHaveLength(1);
  });
});

describe('claudemd.imports-resolve and claudemd.dead-path', () => {
  test('a missing @-import is one error naming the file and line', () => {
    const found = findingsOf(
      {
        files: {'CLAUDE.md': 'Intro.\n\n@docs/missing.md\n'},
        git: true,
      },
      'claudemd.imports-resolve'
    );

    expect(found).toHaveLength(1);
    expect(found[0]).toMatchObject({
      file: 'CLAUDE.md',
      line: 3,
      severity: 'error',
    });
  });

  test('an @ inside an email, a code span or a fence, or a bare mention, is not an import', () => {
    expect(
      findingsOf(
        {
          files: {
            'CLAUDE.md': [
              'Mail me@example.com.',
              'Use `@docs/missing.md` literally.',
              '@someone reviews this.',
              '```',
              '@docs/also-missing.md',
              '```',
              '',
            ].join('\n'),
          },
          git: true,
        },
        'claudemd.imports-resolve'
      )
    ).toEqual([]);
  });

  test('an import resolves against the importing file folder or the root', () => {
    expect(
      findingsOf(
        {
          files: {
            'CLAUDE.md': 'Root rules.\n',
            'docs/root-guide.md': '# Guide\n',
            'frontend/CLAUDE.md': '@guide.md\n@docs/root-guide.md\n',
            'frontend/guide.md': '# Guide\n',
          },
          git: true,
        },
        'claudemd.imports-resolve'
      )
    ).toEqual([]);
  });

  test('an untracked CLAUDE.local.md with a dead import is still checked', () => {
    const scratch = createScratchProject({
      files: {'CLAUDE.md': 'Project rules.\n'},
      git: true,
    });

    cleanups.push(scratch.cleanup);
    writeFileSync(
      path.join(scratch.root, 'CLAUDE.local.md'),
      '@notes/missing.md\n'
    );

    const report = runCheck({
      catalog: CLAUDEMD_RULES,
      env: scratch.env,
      root: scratch.root,
      scope: 'all',
    });

    expect(
      report.findings
        .filter((finding) => finding.rule_id === 'claudemd.imports-resolve')
        .map((finding) => finding.file)
    ).toEqual(['CLAUDE.local.md']);
  });

  test('a missing backticked repo path is one warning, a code-fenced one is ignored', () => {
    const found = findingsOf(
      {
        files: {
          'CLAUDE.md': 'See `docs/missing.md`.\n```\n`docs/fenced.md`\n```\n',
          'docs/index.md': '# Docs\n',
        },
        git: true,
      },
      'claudemd.dead-path'
    );

    expect(found).toHaveLength(1);
    expect(found[0]).toMatchObject({
      file: 'CLAUDE.md',
      line: 1,
      severity: 'warning',
    });
  });

  test('a markdown link is also tried against the file folder', () => {
    expect(
      findingsOf(
        {
          files: {
            'CLAUDE.md': 'Root rules.\n',
            'frontend/CLAUDE.md': 'See [the guide](guide.md).\n',
            'frontend/guide.md': '# Guide\n',
          },
          git: true,
        },
        'claudemd.dead-path'
      )
    ).toEqual([]);
  });

  test('slash commands, urls, globs and placeholders are not paths', () => {
    expect(
      findingsOf(
        {
          files: {
            'CLAUDE.md': [
              'Run `/gaia-debt` or `/gaia-fitness`.',
              'Docs: https://example.com/docs/page.md and [site](https://example.com/a.md).',
              'Match `src/**/*.ts` or `<dir>/file.md` or `$HOME/file.md`.',
              'Call `console.log` then `pnpm test`.',
            ].join('\n'),
          },
          git: true,
        },
        'claudemd.dead-path'
      )
    ).toEqual([]);
  });

  test('a gitignored runtime path that is absent is not dead', () => {
    expect(
      findingsOf(
        {
          files: {
            '.gitignore': 'runtime/\n',
            'CLAUDE.md': 'Output lands in `runtime/output.json`.\n',
          },
          git: true,
        },
        'claudemd.dead-path'
      )
    ).toEqual([]);
  });
});

describe('claudemd.path-outside-root', () => {
  test('a home-relative import is reported as outside the root, not as dead', () => {
    const project: FixtureProject = {
      files: {'CLAUDE.md': '@~/notes/personal.md\n'},
      git: true,
    };

    expect(findingsOf(project, 'claudemd.path-outside-root')).toHaveLength(1);
    expect(findingsOf(project, 'claudemd.imports-resolve')).toEqual([]);
  });

  test('an import through a symlink that leaves the root is info and the target is never read', async () => {
    const scratch = createScratchProject({
      files: {'CLAUDE.md': '@linked.md\n'},
      git: true,
    });
    const outside = mkdtempSync(path.join(tmpdir(), 'gaia-fitness-outside-'));
    const target = path.join(outside, 'secret.md');

    cleanups.push(scratch.cleanup, () => {
      rmSync(outside, {force: true, recursive: true});
    });
    writeFileSync(target, 'outside contents\n');
    chmodSync(target, 0);
    symlinkSync(target, path.join(scratch.root, 'linked.md'));

    const result = await runFitness(['check', '--root', scratch.root], {
      env: scratch.env,
    });
    const report = result.json as {findings: Finding[]};

    expect(result.exitCode).toBe(0);
    expect(
      report.findings.filter(
        (finding) => finding.rule_id === 'claudemd.path-outside-root'
      )
    ).toMatchObject([{file: 'CLAUDE.md', line: 1, severity: 'info'}]);
    expect(
      report.findings.filter(
        (finding) => finding.rule_id === 'claudemd.imports-resolve'
      )
    ).toEqual([]);
  });
});

describe('claudemd.no-absolute-machine-path', () => {
  const homePath = ['', 'home', 'someone', 'project'].join('/');
  const windowsPath = ['C:', 'Users', 'someone', 'project'].join('\\');

  test('flags unix home paths and drive-letter user paths in each governed file', () => {
    const files = {
      '.claude/agents/example.md': `---\nname: example\n---\nRead ${homePath}/a.txt\n`,
      '.claude/commands/example.md': `Read ${windowsPath}\\a.txt\n`,
      '.claude/rules/example.md': `Read ${homePath}/a.txt\n`,
      '.claude/skills/example/SKILL.md': `Read ${homePath}/a.txt\n`,
      'CLAUDE.md': `Read ${homePath}/a.txt\n`,
    };

    expect(
      findingsOf({files, git: true}, 'claudemd.no-absolute-machine-path').map(
        (finding) => finding.file
      )
    ).toEqual(Object.keys(files));
  });

  test('CLAUDE.local.md is exempt, and the finding never quotes the path', () => {
    const scratch = createScratchProject({
      files: {'CLAUDE.md': `Read ${homePath}/a.txt\n`},
      git: true,
    });

    cleanups.push(scratch.cleanup);
    writeFileSync(
      path.join(scratch.root, 'CLAUDE.local.md'),
      `Read ${homePath}/b.txt\n`
    );

    const found = runCheck({
      catalog: CLAUDEMD_RULES,
      env: scratch.env,
      root: scratch.root,
      scope: 'all',
    }).findings.filter(
      (finding) => finding.rule_id === 'claudemd.no-absolute-machine-path'
    );

    expect(found.map((finding) => finding.file)).toEqual(['CLAUDE.md']);
    expect(JSON.stringify(found)).not.toContain('someone');
  });

  test('a placeholder user name is not a machine path', () => {
    expect(
      findingsOf(
        {
          files: {
            'CLAUDE.md': 'Use /Users/<name>/project or /home/<user>/x.\n',
          },
          git: true,
        },
        'claudemd.no-absolute-machine-path'
      )
    ).toEqual([]);
  });
});
