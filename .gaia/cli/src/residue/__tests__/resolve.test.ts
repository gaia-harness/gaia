import {describe, expect, test} from 'vitest';
import type {CorpusProvider} from '../corpus.js';
import {resolveCitedLine, unresolvedResolver} from '../resolve.js';

const fakeProvider = (params: {
  currentText?: null | string;
  headText?: null | string;
}): CorpusProvider => ({
  blobAt: () => params.headText ?? null,
  blobAtHead: () => params.currentText ?? null,
  mergedPrs: () => ({ok: true, prs: [], truncated: false}),
  techDebtIssues: () => ({issues: [], ok: true}),
});

describe('resolveCitedLine classifies still, moved, gone and unresolvable', () => {
  test.each<{
    currentText?: null | string;
    expected: {resolution: string; resolved_line_text: string};
    headText?: null | string;
    title: string;
  }>([
    {
      currentText: 'line one\nline two\nline three\n',
      expected: {resolution: 'still', resolved_line_text: 'line two'},
      headText: 'line one\nline two\nline three\n',
      title: 'still: the cited content is unchanged at current HEAD, same line',
    },
    {
      currentText: 'preamble\nline one\nline two\nline three\n',
      expected: {resolution: 'moved', resolved_line_text: 'line two'},
      headText: 'line one\nline two\nline three\n',
      title: 'moved: the cited content survives but at a different line',
    },
    {
      currentText: 'entirely different content\n',
      expected: {resolution: 'gone', resolved_line_text: 'line two'},
      headText: 'line one\nline two\n',
      title: 'gone: the cited content appears nowhere at current HEAD',
    },
    {
      currentText: null,
      expected: {resolution: 'gone', resolved_line_text: 'line two'},
      headText: 'line one\nline two\n',
      title: 'gone: the file is absent at current HEAD',
    },
    {
      currentText: 'anything\n',
      expected: {resolution: 'unresolvable', resolved_line_text: ''},
      headText: 'line one\n   \nline three\n',
      title: 'unresolvable: the cited line is blank at the head object',
    },
    {
      expected: {resolution: 'unresolvable', resolved_line_text: ''},
      headText: null,
      title: 'unresolvable: the head object could not be read at all',
    },
  ])('$title', ({currentText, expected, headText}) => {
    const provider = fakeProvider({currentText, headText});

    expect(
      resolveCitedLine(provider, {
        headSha: 'abc',
        line: 2,
        path: 'x.ts',
        prNumber: 1,
      })
    ).toEqual(expected);
  });
});

describe('unresolvedResolver', () => {
  test('unresolvedResolver never touches the provider and always reports unresolved', () => {
    expect(unresolvedResolver()).toEqual({
      resolution: 'unresolved',
      resolved_line_text: '',
    });
  });
});
