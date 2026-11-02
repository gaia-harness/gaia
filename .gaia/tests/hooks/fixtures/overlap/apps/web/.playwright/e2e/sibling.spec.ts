import {expect, test} from '@playwright/test';

test('shows the records page', async ({page}) => {
  await page.goto('/records');
  expect(await page.title()).toBe('Records');
});

test('commented assertion', async ({page}) => {
  await page.goto('/records');
  // expect(await page.title()).toBe('Hidden gem');
  expect(1).toBe(1);
});

test.skip('skipped assertion', async ({page}) => {
  expect(await page.title()).toBe('Skipped title');
});

test.describe.skip('skipped group', () => {
  test('inside skipped group', async () => {
    expect(2).toBe(2);
  });
});
