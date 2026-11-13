import {expectNoSeriousA11yViolations} from '../a11y';
import {test} from '../fixtures';
import {expectDarkTheme} from '../theme';
import {hydration} from '../utils';

test('a scan after a theme switch waits for colors to finish easing', async ({
  page,
}, testInfo) => {
  await page.goto('/');
  await hydration(page);

  // The negative delay starts the transition 70% of the way from the light
  // to the dark primary colors, where the pair is about 3:1, and leaves
  // 3 seconds to run: a scan that does not wait reads that frame and fails.
  await page.evaluate(() => {
    const button = document.createElement('button');
    button.className = 'bg-primary text-primary-foreground';
    button.style.transition = 'all 10s linear -7s';
    button.textContent = 'Sign in';
    document.querySelector('main')?.append(button);
    // Resolve the light colors first: with no prior style there is nothing
    // to transition from, and the button would paint dark at once.
    button.getBoundingClientRect();
    document.documentElement.classList.add('dark');
  });

  await expectDarkTheme(page);
  await expectNoSeriousA11yViolations(page, testInfo, {label: 'dark'});
});
