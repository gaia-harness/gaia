import addonA11y from '@storybook/addon-a11y';
import addonLinks from '@storybook/addon-links';
import {definePreview} from '@storybook/react-vite';
import addonMsw from 'msw-storybook-addon';
import storybookReactI18next from 'storybook-react-i18next/preview';
// Storybook internal import: it can change in any upgrade.
import type {AddonTypes} from 'storybook/internal/csf';
import {definePreviewAddon} from 'storybook/internal/csf';
import {themes} from 'storybook/theming';
import {DEFAULT_LOCALE} from '~/i18n';
import a11y from './a11y';
import {decorators} from './chromatic';
import i18n from './i18next';
import {allModes} from './modes';
import viewport from './viewport';
import '~/styles/tailwind.css';

const storybookBrandOptions = {
  brandTarget: '_blank',
  brandTitle: 'GAIA',
  brandUrl: 'https://docs.gaiaharness.com/',
};

export default definePreview({
  addons: [
    addonA11y(),
    addonLinks(),
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-type-arguments -- the explicit argument is the documented CSF Next wiring
    definePreviewAddon<AddonTypes>(storybookReactI18next),
    addonMsw(),
  ],
  decorators,
  initialGlobals: {
    locale: DEFAULT_LOCALE,
    locales: {
      en: {left: '🇺🇸', right: 'en', title: 'English'},
    },
    // Read only by the Chromatic decorator. Declared here because Storybook
    // drops a global it has no initial value for, which would silently turn
    // the dark mode into a second light snapshot.
    theme: 'light',
  },
  // The i18n addon switches language in an effect after the first render, so a
  // play function that queries at once can race it and read English. Loaders
  // finish before render and play, which makes a story's locale deterministic.
  loaders: [
    async ({globals}) => {
      const locale =
        typeof globals.locale === 'string' ? globals.locale : DEFAULT_LOCALE;

      if (i18n.language !== locale) await i18n.changeLanguage(locale);
    },
  ],
  parameters: {
    a11y,
    chromatic: {modes: allModes},
    controls: {
      expanded: false,
      matchers: {
        color: /(background|color)$/i,
        date: /Date$/,
      },
    },
    darkMode: {
      dark: {
        ...themes.dark,
        ...storybookBrandOptions,
      },
      darkClass: ['dark', 'bg-background', 'text-foreground'],
      light: {
        ...themes.light,
        ...storybookBrandOptions,
      },
      lightClass: ['light', 'bg-background', 'text-foreground'],
      stylePreview: true,
    },
    i18n,
    layout: 'fullscreen',
    viewport,
  },
});
