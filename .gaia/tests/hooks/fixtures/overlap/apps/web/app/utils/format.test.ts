import {expect, test} from 'vitest';

test('formats a title', () => {
  expect(formatTitle('a')).toBe('A');
});
