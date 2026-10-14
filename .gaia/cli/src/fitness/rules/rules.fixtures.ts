import type {FixtureMap} from '../types.js';

const RULE = '.claude/rules/example.md';

export const RULES_FIXTURES: FixtureMap = {
  'rules.dead-path': {
    green: () => ({
      files: {
        'CLAUDE.md': 'Project rules.\n',
        'docs/guide.md': '# Guide\n',
        [RULE]: 'Read `docs/guide.md` first.\n',
      },
      git: true,
    }),
    red: () => ({
      files: {
        'CLAUDE.md': 'Project rules.\n',
        'docs/index.md': '# Docs\n',
        [RULE]: 'Read `docs/missing.md` first.\n',
      },
      git: true,
    }),
  },
  'rules.glob-syntax': {
    green: () => ({
      files: {
        'CLAUDE.md': 'Project rules.\n',
        [RULE]: '---\npaths:\n  - "src/**/*.{ts,tsx}"\n---\nKeep it short.\n',
      },
      git: true,
    }),
    red: () => ({
      files: {
        'CLAUDE.md': 'Project rules.\n',
        [RULE]: '---\npaths:\n  - "[abc"\n---\nKeep it short.\n',
      },
      git: true,
    }),
  },
  'rules.no-skill-import': {
    green: () => ({
      files: {
        'CLAUDE.md': 'Project rules.\n',
        'docs/guide.md': '# Guide\n',
        [RULE]: '@docs/guide.md\n',
      },
      git: true,
    }),
    red: () => ({
      files: {
        '.claude/skills/example/SKILL.md': '# Example\n',
        'CLAUDE.md': 'Project rules.\n',
        [RULE]: '@.claude/skills/example/SKILL.md\n',
      },
      git: true,
    }),
  },
};
