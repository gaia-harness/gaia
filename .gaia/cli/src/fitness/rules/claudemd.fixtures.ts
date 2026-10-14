import {ROOT_CLAUDE_MD_WORD_BUDGET} from '../budgets.js';
import type {FixtureMap} from '../types.js';

/** `count` whitespace-separated words, ending in a newline. */
export const wordsOf = (count: number): string =>
  `${Array.from({length: count}, () => 'word').join(' ')}\n`;

/** A user-home path assembled at call time, so no machine path is a committed literal. */
const machinePath = (): string =>
  ['', 'Users', 'someone', 'project', 'file.txt'].join('/');

export const CLAUDEMD_FIXTURES: FixtureMap = {
  'claudemd.budget': {
    green: () => ({
      files: {'CLAUDE.md': wordsOf(ROOT_CLAUDE_MD_WORD_BUDGET)},
      git: true,
    }),
    red: () => ({
      files: {'CLAUDE.md': wordsOf(ROOT_CLAUDE_MD_WORD_BUDGET + 1)},
      git: true,
    }),
  },
  'claudemd.dead-path': {
    green: () => ({
      files: {
        'CLAUDE.md': 'See `docs/guide.md` for the guide.\n',
        'docs/guide.md': '# Guide\n',
      },
      git: true,
    }),
    red: () => ({
      files: {
        'CLAUDE.md': 'See `docs/missing.md` for the guide.\n',
        'docs/index.md': '# Docs\n',
      },
      git: true,
    }),
  },
  'claudemd.imports-resolve': {
    green: () => ({
      files: {
        'CLAUDE.md': '@docs/guide.md\n',
        'docs/guide.md': '# Guide\n',
      },
      git: true,
    }),
    red: () => ({
      files: {'CLAUDE.md': '@docs/missing.md\n'},
      git: true,
    }),
  },
  'claudemd.missing-root': {
    green: () => ({files: {'CLAUDE.md': 'Project rules.\n'}, git: true}),
    red: () => ({files: {'README.md': '# Project\n'}, git: true}),
  },
  'claudemd.no-absolute-machine-path': {
    green: () => ({
      files: {'CLAUDE.md': 'Run `scripts/build.sh` from the root.\n'},
      git: true,
    }),
    red: () => ({
      files: {'CLAUDE.md': `Edit ${machinePath()} before building.\n`},
      git: true,
    }),
  },
  'claudemd.path-outside-root': {
    green: () => ({
      files: {
        'CLAUDE.md': 'See `docs/guide.md` for the guide.\n',
        'docs/guide.md': '# Guide\n',
      },
      git: true,
    }),
    red: () => ({
      files: {'CLAUDE.md': 'See `../shared/guide.md` for the guide.\n'},
      git: true,
    }),
  },
};
