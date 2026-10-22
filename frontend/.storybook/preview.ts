import type {Preview} from '@storybook/react-vite';
import {mswLoader} from 'msw-storybook-addon/csf3';
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
  brandUrl: 'https://gaiareact.com/docs/',
};

const preview: Preview = {
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
    mswLoader(),
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
      hideNoControlsWarning: true,
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
};

export default preview;
