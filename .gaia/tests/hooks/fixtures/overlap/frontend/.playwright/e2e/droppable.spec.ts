import {expect, test} from '@playwright/test';

test('repeats the records title', async ({page}) => {
  await page.goto('/records');
  expect(await page.title()).toBe('Records');
});
