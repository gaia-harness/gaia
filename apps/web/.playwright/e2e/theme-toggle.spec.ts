import {ACTION_PATHS} from '../../app/action-paths';
import {expect, test} from '../fixtures';
import {hydration} from '../utils';

test('theme toggle POST resolves 2xx', async ({page}) => {
  await page.goto('/');
  await hydration(page);

  const toggle = page.getByRole('button', {
    name: /enable (dark|light) mode|use system theme/i,
  });
  await expect(toggle).toBeVisible();

  const [response] = await Promise.all([
    page.waitForResponse(
      (candidateResponse) =>
        candidateResponse.request().method() === 'POST' &&
        new URL(candidateResponse.url()).pathname.startsWith(
          ACTION_PATHS.themeSwitch
        )
    ),
    toggle.click(),
  ]);
  expect(response.status()).toBeGreaterThanOrEqual(200);
  expect(response.status()).toBeLessThan(300);
});
