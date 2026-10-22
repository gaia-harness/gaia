import {describe, expect, test, vi} from 'vitest';
import type * as I18nModule from '~/i18n';

// Every app locale is 'en' by default, so a literal 'en' in the Storybook setup
// is indistinguishable from DEFAULT_LOCALE until a project changes it. Swapping
// in i18next's built-in `cimode` locale makes the two diverge.
vi.mock('~/i18n', async (importOriginal) => ({
  ...(await importOriginal<typeof I18nModule>()),
  DEFAULT_LOCALE: 'cimode',
}));

describe('Storybook default locale', () => {
  test('the initial locale global follows DEFAULT_LOCALE', async () => {
    const {default: preview} = await import('../.storybook/preview');

    expect(preview.initialGlobals?.locale).toBe('cimode');
  });

  test('the Storybook i18next instance starts in DEFAULT_LOCALE', async () => {
    const {default: i18n} = await import('../.storybook/i18next');

    expect(i18n.language).toBe('cimode');
  });
});
