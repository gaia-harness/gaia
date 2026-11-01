import {expect, test} from 'vitest';

test('refuses blank input', () => {
  expect(validate('')).toBe(false);
});
