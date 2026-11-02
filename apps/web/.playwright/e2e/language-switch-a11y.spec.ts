import {LANGUAGES} from '~/languages';
import {expectNoSeriousA11yViolations} from '../a11y';
import {expect, test} from '../fixtures';
import {hydration} from '../utils';

test('language switcher has no serious a11y violations', async ({
  page,
}, testInfo) => {
  await page.goto('/');
  await hydration(page);

  // playwright.config.ts runs this spec only when LANGUAGES has two or more
  // entries, the condition under which the switcher renders.
  const switcher = page.locator('select[name="language"]');
  const rootElement = page.locator('html');

  // Smoke-test the switcher in its initial state.
  await expectNoSeriousA11yViolations(page, testInfo, {label: 'initial'});

  // LanguageSelect drops a pick of the current language, so the target must
  // differ from whatever language the page starts in. Waiting for html[lang] is
  // what proves the next scan covers a switched page.
  const initialLanguage = await rootElement.getAttribute('lang');
  const targetLanguage = LANGUAGES.find(
    (language) => language !== initialLanguage
  ) as string;

  await switcher.selectOption(targetLanguage);
  await expect(rootElement).toHaveAttribute('lang', targetLanguage);

  await expectNoSeriousA11yViolations(page, testInfo, {label: 'after-switch'});
});
