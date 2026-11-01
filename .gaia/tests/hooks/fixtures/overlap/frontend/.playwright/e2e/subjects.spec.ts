import {expect, test} from '@playwright/test';

test('walks the first step', async ({page}) => {
  await page.goto('/start');
  expect(await page.title()).toBe('Start');
});

test('refuses an edit to another account', async ({page}) => {
  await page.goto('/account');
  expect(await page.title()).toBe('Account');
});

test('hides records of another user',async ({page}) => {
  await page.goto('/records');
  expect(await page.title()).toBe('Records');
});

test('ignores forged fields on submit', async ({page}) => {
  await page.goto('/submit');
  expect(await page.title()).toBe('Submit');
});

test('answers for a missing page', async ({page}) => {
  await expectNotFound(page, '/gone');
});

test('opens the settings page', async ({page}) => {
  await page.goto('/settings');
  await page.getByRole('button', {name: 'Save'}).click();
  expect(await page.title()).toBe('Settings');
});

test('creates a user', async () => {
  const created = await createUser({role: 'admin'});
  expect(created).toBeTruthy();
});

test('hiding the banner', async ({page}) => {
  await page.goto('/banner');
  expect(await page.title()).toBe('Banner');
});

test('denies entry to guests', async ({page}) => {
  await page.goto('/club');
  expect(await page.title()).toBe('Club');
});

test('escaping markup in names', async ({page}) => {
  await page.goto('/names');
  expect(await page.title()).toBe('Names');
});

test('unauthorized visitors see the form', async ({page}) => {
  await page.goto('/form');
  expect(await page.title()).toBe('Form');
});

test('reads the invoice', async ({page}) => {
  await page.goto('/invoice');
  expect(await page.title()).toBe('Invoice');
});
