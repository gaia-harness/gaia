import {afterEach, describe, expect, test} from 'vitest';
import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {discoverFiles, hasPathScope, kindsOfPath} from './discover.js';
import {createScratchProject, runFitness} from './test-support.js';
import type {FixtureProject} from './types.js';

const cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

const scratch = (project: FixtureProject) => {
  const created = createScratchProject({classifier: 'none', ...project});

  cleanups.push(created.cleanup);

  return created;
};

const pathsOf = (root: string): string[] =>
  discoverFiles(root).files.map((file) => file.path);

describe('kindsOfPath', () => {
  test.each([
    ['.claude/skills/example/SKILL.md', ['skill']],
    ['.claude/skills/example/references/more.md', ['reference']],
    ['.claude/commands/nested/example.md', ['command']],
    ['.claude/agents/example.md', ['agent']],
    ['.claude/rules/example.md', ['rule']],
    ['CLAUDE.md', ['claudemd']],
    ['a/b/CLAUDE.md', ['claudemd']],
    ['a/b/c/CLAUDE.md', []],
    ['a/CLAUDE.local.md', ['claudemd-local']],
    ['wiki/concepts/Page.md', ['wiki']],
    ['.claude/settings.json', ['settings']],
    ['frontend/.claude/settings.json', ['settings']],
    ['.claude/settings.local.json', ['settings-local']],
    ['.claude/gaia-fitness.json', ['fitness-config']],
    ['src/index.ts', []],
  ])('%s', (relative, expected) => {
    expect(kindsOfPath(relative)).toEqual(expected);
  });
});

describe('discoverFiles inside git', () => {
  test('discovers a depth-3 CLAUDE.md and not a depth-4 one', () => {
    const {root} = scratch({
      files: {'a/b/c/CLAUDE.md': '# y\n', 'a/b/CLAUDE.md': '# x\n'},
      git: true,
    });

    expect(pathsOf(root)).toEqual(['a/b/CLAUDE.md']);
  });

  test('skips an untracked file', () => {
    const {root} = scratch({files: {'CLAUDE.md': '# x\n'}, git: true});

    mkdirSync(path.join(root, '.claude/rules'), {recursive: true});
    writeFileSync(path.join(root, '.claude/rules/untracked.md'), '# u\n');

    expect(pathsOf(root)).toEqual(['CLAUDE.md']);
  });

  test('discovers an untracked settings.local.json and CLAUDE.local.md but keeps them out of the tracked set', () => {
    const {root} = scratch({files: {'CLAUDE.md': '# x\n'}, git: true});

    mkdirSync(path.join(root, '.claude'), {recursive: true});
    mkdirSync(path.join(root, 'a'), {recursive: true});
    writeFileSync(path.join(root, '.claude/settings.local.json'), '{}\n');
    writeFileSync(path.join(root, 'a/CLAUDE.local.md'), '# local\n');

    const discovery = discoverFiles(root);

    expect(discovery.files.map((file) => file.path)).toEqual([
      '.claude/settings.local.json',
      'CLAUDE.md',
      'a/CLAUDE.local.md',
    ]);
    expect(discovery.allTrackedPaths.has('CLAUDE.md')).toBe(true);
    expect(discovery.allTrackedPaths.has('.claude/settings.local.json')).toBe(
      false
    );
    expect(discovery.allTrackedPaths.has('a/CLAUDE.local.md')).toBe(false);
  });

  test('marks a Read target under .claude as a playbook and not a wiki page', () => {
    const {root} = scratch({
      files: {
        '.claude/commands/example.md':
          'Read `.claude/skills/example/references/flow.md` now.\nRead `wiki/notes.md` too.\n',
        '.claude/skills/example/references/flow.md': '# flow\n',
        'wiki/notes.md': '# notes\n',
      },
      git: true,
    });
    const byPath = new Map(
      discoverFiles(root).files.map((file) => [file.path, file.kinds])
    );

    expect(byPath.get('.claude/skills/example/references/flow.md')).toEqual([
      'playbook',
      'reference',
    ]);
    expect(byPath.get('wiki/notes.md')).toEqual(['wiki']);
  });

  test('resolves a Read target against the routing file directory too', () => {
    const {root} = scratch({
      files: {
        '.claude/skills/example/references/flow.md': '# flow\n',
        '.claude/skills/example/SKILL.md': 'Read `references/flow.md`.\n',
      },
      git: true,
    });
    const byPath = new Map(
      discoverFiles(root).files.map((file) => [file.path, file.kinds])
    );

    expect(byPath.get('.claude/skills/example/references/flow.md')).toContain(
      'playbook'
    );
  });

  test('does not mark a Read target that does not exist', () => {
    const {root} = scratch({
      files: {'.claude/commands/example.md': 'Read `.claude/missing.md`.\n'},
      git: true,
    });

    expect(pathsOf(root)).toEqual(['.claude/commands/example.md']);
  });
});

describe('discoverFiles outside git', () => {
  test('skips node_modules and .claude/worktrees', () => {
    const {root} = scratch({
      files: {
        '.claude/rules/kept.md': '# kept\n',
        '.claude/worktrees/other/.claude/rules/dropped.md': '# dropped\n',
        'node_modules/pkg/CLAUDE.md': '# dropped\n',
      },
    });

    expect(pathsOf(root)).toEqual(['.claude/rules/kept.md']);
  });
});

describe('inventory path_scoped', () => {
  test('is true for a rule with a non-empty paths and false without', async () => {
    const {env, root} = scratch({
      classifier: 'repo',
      files: {
        '.claude/rules/scoped.md': '---\npaths:\n  - "src/**"\n---\n# scoped\n',
        '.claude/rules/unscoped.md': '# unscoped\n',
      },
      git: true,
    });
    const result = await runFitness(['check', '--root', root], {env});
    const {inventory} = result.json as {
      inventory: {path: string; path_scoped: boolean}[];
    };

    expect(
      inventory.find((entry) => entry.path === '.claude/rules/scoped.md')
        ?.path_scoped
    ).toBe(true);
    expect(
      inventory.find((entry) => entry.path === '.claude/rules/unscoped.md')
        ?.path_scoped
    ).toBe(false);
  });
});

describe('hasPathScope', () => {
  test.each([
    ['---\npaths: "src/**"\n---\n', true],
    ['---\npaths:\n  - a\n---\n', true],
    ['---\npaths: []\n---\n', false],
    ['---\npaths: ""\n---\n', false],
    ['---\nname: x\n---\n', false],
    ['# no frontmatter\n', false],
  ])('%j', (text, expected) => {
    expect(hasPathScope(text)).toBe(expected);
  });
});

describe('discoverFiles word and line counts', () => {
  test('are reported as wc -w and wc -l', async () => {
    const {env, root} = scratch({
      classifier: 'repo',
      files: {'CLAUDE.md': 'one two\nthree\n'},
      git: true,
    });
    const result = await runFitness(['check', '--root', root], {env});
    const entry = (
      result.json as {inventory: {lines: number; path: string; words: number}[]}
    ).inventory.find((candidate) => candidate.path === 'CLAUDE.md');

    expect(entry?.words).toBe(3);
    expect(entry?.lines).toBe(2);
  });
});
