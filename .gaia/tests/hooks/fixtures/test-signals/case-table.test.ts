import {expect, test} from 'vitest';

test.for([{email: 'a@x.io'}, {email: 'b@x.io'}])('rejects $email', ({email}) => {
  expect(email).toBe('');
});

test('rejects static', () => {
  expect(1).toBe(2);
});
