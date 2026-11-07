import {expect, test} from 'vitest';

test.for([{first: 'ann'}])('signs in $first', ({first}) => {
  expect(first).toBe('');
});

test.for([{last: 'lee'}])('signs in $last', ({last}) => {
  expect(last).toBe('');
});
