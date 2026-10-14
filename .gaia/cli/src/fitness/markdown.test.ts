import {describe, expect, test} from 'vitest';
import {
  lineOf,
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

  test('is not ok without frontmatter', () => {
    const result = splitFrontmatter('# Heading\n');

    expect(result.ok).toBe(false);
    expect(result.data).toEqual({});
  });

  test('is not ok for an unclosed block', () => {
    expect(splitFrontmatter('---\nname: x\n').ok).toBe(false);
  });

  test('reports a YAML error without throwing', () => {
    const result = splitFrontmatter('---\nname: [unclosed\n---\n');

    expect(result.ok).toBe(false);
    expect(result.error).toBeDefined();
  });

  test('is not ok when the block is not a mapping', () => {
    expect(splitFrontmatter('---\n- a\n- b\n---\n').ok).toBe(false);
  });

  test('treats an empty block as ok with no data', () => {
    const result = splitFrontmatter('---\n---\nBody');

    expect(result.ok).toBe(true);
    expect(result.data).toEqual({});
  });
});

describe('stripFencedCode', () => {
  test('blanks fenced blocks and keeps the line count', () => {
    const text = 'before\n```bash\nrm -rf x\n```\nafter';
    const stripped = stripFencedCode(text);

    expect(stripped.split('\n')).toHaveLength(text.split('\n').length);
    expect(stripped).not.toContain('rm -rf');
    expect(stripped.startsWith('before')).toBe(true);
    expect(stripped.endsWith('after')).toBe(true);
  });

  test('a longer fence is not closed by a shorter one', () => {
    const stripped = stripFencedCode('````\n```\ninside\n```\n````\nout');

    expect(stripped).not.toContain('inside');
    expect(stripped.endsWith('out')).toBe(true);
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

describe('lineOf', () => {
  test('counts lines from 1', () => {
    const text = 'a\nbb\nccc';

    expect(lineOf(text, 0)).toBe(1);
    expect(lineOf(text, 2)).toBe(2);
    expect(lineOf(text, 5)).toBe(3);
  });
});
