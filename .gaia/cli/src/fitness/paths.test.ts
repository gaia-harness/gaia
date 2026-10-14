import {describe, expect, test} from 'vitest';
import {
  asRepositoryPath,
  extractImports,
  extractPathReferences,
} from './paths.js';

describe('asRepositoryPath', () => {
  test.each([
    ['docs/guide.md', 'docs/guide.md'],
    ['package.json', 'package.json'],
    ['.claude/hooks/', '.claude/hooks/'],
    ['src/app.ts:12', 'src/app.ts'],
    ['docs/guide.md#top', 'docs/guide.md'],
    ['../shared/guide.md', '../shared/guide.md'],
  ])('%s is a path', (candidate, expected) => {
    expect(asRepositoryPath(candidate)).toBe(expected);
  });

  test.each([
    '/gaia-debt',
    '/etc/hosts',
    'console.log',
    'v1.2',
    'pnpm test',
    'src/**/*.ts',
    '<dir>/file.md',
    '$HOME/file.md',
    '~/notes.md',
    '-flag/file.md',
    'https://example.com/a.md',
    'a=b/c.md',
    '',
  ])('%s is not a path', (candidate) => {
    expect(asRepositoryPath(candidate)).toBeUndefined();
  });
});

describe('extractPathReferences', () => {
  test('finds backticked and linked paths with their lines and skips fences and frontmatter', () => {
    const text = [
      '---',
      'paths:',
      '  - docs/in-frontmatter.md',
      '---',
      'See `docs/a.md` and [b](docs/b.md#part).',
      '```',
      '`docs/fenced.md`',
      '```',
      'Link in code: `[c](docs/c.md)` and [web](https://example.com/d.md).',
      '',
    ].join('\n');

    expect(extractPathReferences(text)).toEqual([
      {line: 5, linked: false, token: 'docs/a.md'},
      {line: 5, linked: true, token: 'docs/b.md'},
    ]);
  });
});

describe('extractImports', () => {
  test('finds imports at the start of a line or after whitespace only', () => {
    const text = [
      '@docs/a.md',
      'Also see @docs/b.md, and @README.md.',
      'Mail me@example.com or `@docs/code.md`.',
      '@mention is not a file.',
      '- @~/notes.md',
      '',
    ].join('\n');

    expect(extractImports(text)).toEqual([
      {line: 1, token: 'docs/a.md'},
      {line: 2, token: 'docs/b.md'},
      {line: 2, token: 'README.md'},
      {line: 5, token: '~/notes.md'},
    ]);
  });
});
