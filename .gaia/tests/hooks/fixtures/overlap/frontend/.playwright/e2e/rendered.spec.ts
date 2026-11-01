// gaia-uat-contract sha256:0000000000000000000000000000000000000000000000000000000000000000
import {expect, test} from '@playwright/test';

test('shows the rendered page', async ({page}) => {
  await page.goto('/rendered');
  expect(await page.title()).toBe('Rendered');
});
