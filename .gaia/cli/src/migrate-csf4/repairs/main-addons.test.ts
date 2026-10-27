import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {readCheckoutFile} from './repairs-fixture.js';
import {mainAddonSpecifiers} from './index.js';

const ADDONS = `[
    '@storybook/addon-a11y',
    {name: '@storybook/addon-links', options: {}},
    getAbsolutePath('msw-storybook-addon'),
  ]`;
const EXPECTED = [
  '@storybook/addon-a11y',
  '@storybook/addon-links',
  'msw-storybook-addon',
];

const SHAPES = {
  'a defineMain call': `import {defineMain} from '@storybook/react-vite/node';

export default defineMain({
  addons: ${ADDONS},
  framework: '@storybook/react-vite',
});
`,
  'a directly exported object': `import type {StorybookConfig} from '@storybook/react-vite';

export default {
  addons: ${ADDONS},
  framework: '@storybook/react-vite',
} satisfies StorybookConfig;
`,
  'a StorybookConfig bound to a const': `import type {StorybookConfig} from '@storybook/react-vite';

const config: StorybookConfig = {
  addons: ${ADDONS},
  framework: '@storybook/react-vite',
};

export default config;
`,
};

describe('mainAddonSpecifiers', () => {
  test.each(Object.entries(SHAPES))(
    'reads string, object and wrapped entries from %s',
    (_shape, source) => {
      expect(mainAddonSpecifiers(ts, source)).toEqual(EXPECTED);
    }
  );

  test("reads GAIA's own main", () => {
    expect(
      mainAddonSpecifiers(ts, readCheckoutFile('frontend/.storybook/main.ts'))
    ).toEqual([
      '@storybook/addon-a11y',
      '@storybook/addon-links',
      '@storybook/addon-vitest',
      'storybook-react-i18next',
      '@vueless/storybook-dark-mode',
      'msw-storybook-addon',
    ]);
  });

  test('a main without an addons array reads as no addons', () => {
    expect(
      mainAddonSpecifiers(ts, 'export default {framework: "x"};\n')
    ).toEqual([]);
    expect(
      mainAddonSpecifiers(ts, 'const addons = [];\nexport default {addons};\n')
    ).toEqual([]);
    expect(
      mainAddonSpecifiers(ts, 'module.exports = {addons: ["a"]};\n')
    ).toEqual([]);
  });
});
