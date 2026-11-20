import {describe, expect, test} from 'vitest';
import {isVisualStoryEntry} from '../.playwright/story-index';

describe('isVisualStoryEntry keeps stories and drops test and docs entries', () => {
  test.each([
    [
      'a story entry, a test entry and a docs entry',
      [
        {id: 'button--default', subtype: 'story', type: 'story'},
        {id: 'button--default:clicks', subtype: 'test', type: 'story'},
        {id: 'button--docs', type: 'docs'},
      ],
      ['button--default'],
    ],
    [
      'a story entry that carries no subtype',
      [{id: 'button--plain', type: 'story'}],
      ['button--plain'],
    ],
  ])('keeps only the visual entries of %s', (_name, entries, keptIds) => {
    expect(entries.filter(isVisualStoryEntry).map(({id}) => id)).toEqual(
      keptIds
    );
  });
});
