import type {KnipConfig} from 'knip';

export default {
  entry: [
    '.playwright/**/*.ts',
    '.storybook/**/*.{ts,tsx}',
    'app/components/**/*.{ts,tsx}',
    'app/hooks/**/*.ts',
    'app/languages/index.ts',
    'app/middleware/**/*.ts',
    'app/services/**/*.{ts,tsx}',
    'app/types/**/*.ts',
    'app/utils/**/*.ts',
    'test/**/*.{ts,tsx}',
  ],
  ignoreDependencies: [
    // stylelint.config.mjs loads these presets, which @gaia-react/lint provides
    // rather than this package.json.
    'stylelint-config-clean-order',
    'stylelint-config-standard',
    'stylelint-config-tailwindcss',
    'stylelint-order',
    // tailwindcss and tw-animate-css are imported only from CSS (tailwind.css), so knip cannot see them.
    'tailwindcss',
    'tw-animate-css',
  ],
  project: ['app/**/*.{ts,tsx}', 'test/**/*.{ts,tsx}'],
} satisfies KnipConfig;
