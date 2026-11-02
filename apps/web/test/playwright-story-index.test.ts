import {describe, expect, test} from 'vitest';
import {isVisualStoryEntry} from '../.playwright/story-index';

describe('isVisualStoryEntry', () => {
  test('keeps a story entry and drops a test entry and a docs entry', () => {
    const entries = [
      {id: 'button--default', subtype: 'story', type: 'story'},
      {id: 'button--default:clicks', subtype: 'test', type: 'story'},
      {id: 'button--docs', type: 'docs'},
    ];

    expect(entries.filter(isVisualStoryEntry).map(({id}) => id)).toEqual([
      'button--default',
    ]);
  });

  test('keeps a story entry that carries no subtype', () => {
    expect(isVisualStoryEntry({type: 'story'})).toBe(true);
  });
});
