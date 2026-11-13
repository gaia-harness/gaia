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
  // 6 seconds to run: a scan that does not wait reads that frame and fails.
  await page.evaluate(() => {
    const button = document.createElement('button');
    button.className = 'bg-primary text-primary-foreground';
    button.style.transition = 'all 20s linear -14s';
    button.textContent = 'Sign in';
    const main = document.querySelector('main');
    if (!main) throw new Error('home page has no <main>');
    main.append(button);
    // Resolve the light colors first: with no prior style there is nothing
    // to transition from, and the button would paint dark at once.
    button.getBoundingClientRect();
    document.documentElement.classList.add('dark');
  });

  await expectDarkTheme(page);
  await expectNoSeriousA11yViolations(page, testInfo, {label: 'dark'});
});

test('a scan does not hang on an animation that never finishes', async ({
  page,
}, testInfo) => {
  await page.goto('/');
  await hydration(page);

  await page.evaluate(() => {
    document.body
      .animate([{opacity: 1}, {opacity: 1}], {duration: 1000})
      .pause();
  });

  await expectNoSeriousA11yViolations(page, testInfo, {label: 'paused'});
});
