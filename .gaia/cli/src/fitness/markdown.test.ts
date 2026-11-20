import {describe, expect, test} from 'vitest';
import {
  splitFrontmatter,
  stripFencedCode,
  stripInlineCode,
} from './markdown.js';

describe('splitFrontmatter', () => {
  test('parses a mapping and reports where the body starts', () => {
    const result = splitFrontmatter(
      '---\nname: example\nmodel: opus\n---\nBody\n'
    );

    expect(result.ok).toBe(true);
    expect(result.data).toEqual({model: 'opus', name: 'example'});
    expect(result.raw).toBe('name: example\nmodel: opus');
    expect(result.bodyStartLine).toBe(5);
  });

  test.each<[string, string]>([
    ['is not ok without frontmatter', '# Heading\n'],
    ['is not ok for an unclosed block', '---\nname: x\n'],
    ['reports a YAML error without throwing', '---\nname: [unclosed\n---\n'],
    ['is not ok when the block is not a mapping', '---\n- a\n- b\n---\n'],
  ])('%s', (_name, text) => {
    const result = splitFrontmatter(text);

    expect(result.ok).toBe(false);
    expect(result.data).toEqual({});
    expect(result.error).toBeDefined();
  });

  test('treats an empty block as ok with no data', () => {
    const result = splitFrontmatter('---\n---\nBody');

    expect(result.ok).toBe(true);
    expect(result.data).toEqual({});
  });
});

describe('stripFencedCode', () => {
  test.each<[string, string, string[], string, string]>([
    [
      'blanks fenced blocks and keeps the line count',
      'before\n```bash\nrm -rf x\n```\nafter',
      ['rm -rf'],
      'before',
      'after',
    ],
    [
      'a longer fence is not closed by a shorter one',
      '````\n```\ninside\n```\n````\nout',
      ['inside'],
      '',
      'out',
    ],
  ])('%s', (_name, text, gone, start, end) => {
    const stripped = stripFencedCode(text);

    expect(stripped.split('\n')).toHaveLength(text.split('\n').length);

    for (const fragment of gone) {
      expect(stripped).not.toContain(fragment);
    }
    expect(stripped.startsWith(start)).toBe(true);
    expect(stripped.endsWith(end)).toBe(true);
  });
});

describe('stripInlineCode', () => {
  test('blanks the span and keeps the length', () => {
    const line = 'run `rm -rf x` now';
    const stripped = stripInlineCode(line);

    expect(stripped).toHaveLength(line.length);
    expect(stripped).not.toContain('rm');
    expect(stripped.startsWith('run ')).toBe(true);
  });
});
