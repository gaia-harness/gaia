import {describe, expect, test} from 'vitest';

describe.each([{group: 'a'}, {group: 'b'}])('group $group', ({group}) => {
  test('accepts the group', () => {
    expect(group).toBe('b');
  });

  test.each([1, 2])('counts %s', (count) => {
    expect(count).toBe(2);
  });
});
