import type {Preview} from '@storybook/react-vite';
import '@vueless/storybook-dark-mode';
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
  brandTitle: 'Acme',
  brandUrl: 'https://example.com/',
};

const preview: Preview = {
  decorators,
  initialGlobals: {
    locale: DEFAULT_LOCALE,
    locales: {
      en: {left: '🇺🇸', right: 'en', title: 'English'},
    },
    theme: 'light',
  },
  // Loaders finish before render and play, which makes a story's locale
  // deterministic.
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
