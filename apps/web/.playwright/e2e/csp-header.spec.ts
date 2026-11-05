import {expect, test} from '../fixtures';

test('the home page serves a Content-Security-Policy with a nonce and the pinned directives', async ({
  request,
}) => {
  const response = await request.get('/');
  const policy = response.headers()['content-security-policy'];

  expect(policy).toBeDefined();
  expect(policy).toMatch(/'nonce-[\w+/=-]+'/);
  expect(policy).toContain(`script-src 'self' 'report-sample'`);
  expect(policy).toContain(`style-src 'self' 'unsafe-inline'`);
  expect(policy).toContain(`font-src 'self';`);
  expect(policy).toContain('upgrade-insecure-requests');
});
