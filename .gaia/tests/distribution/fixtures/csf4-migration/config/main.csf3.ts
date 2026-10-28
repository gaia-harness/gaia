// The preview inlines no environment values. Give a story the values it needs
// as args instead.

import type {StorybookConfig} from '@storybook/react-vite';

const config: StorybookConfig = {
  addons: [
    '@storybook/addon-a11y',
    '@storybook/addon-links',
    '@storybook/addon-vitest',
    'storybook-react-i18next',
    '@vueless/storybook-dark-mode',
    'msw-storybook-addon',
  ],

  features: {
    backgrounds: false,
    experimentalDocgenServer: true,
    measure: false,
    outline: false,
  },

  framework: {
    name: '@storybook/react-vite',
    options: {
      builder: {
        viteConfigPath: '.storybook/vite.config.ts',
      },
    },
  },

  staticDirs: ['../public'],

  stories: ['../app/**/*.stories.tsx'],
};

export default config;
