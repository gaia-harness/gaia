import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {readMigrationFixture} from './repairs-fixture.js';
import {rewirePreview} from './index.js';

/** GAIA's CSF3 preview plus a dark-mode addon import, as an adopter may have. */
const ORIGINAL = readMigrationFixture('preview.ts.csf3').replace(
  "import {themes} from 'storybook/theming';",
  "import '@vueless/storybook-dark-mode';\nimport {themes} from 'storybook/theming';"
);

describe('rewirePreview on an original CSF3 Preview object', () => {
  const result = rewirePreview(ts, ORIGINAL);

  test('the fixture opens in the CSF3 form with every addon wired', () => {
    expect(ORIGINAL).toContain(
      "import type {Preview} from '@storybook/react-vite';"
    );
    expect(ORIGINAL).toContain(
      "import {mswLoader} from 'msw-storybook-addon/csf3';"
    );
    expect(ORIGINAL).toContain('    mswLoader(),');
    expect(ORIGINAL).toContain('    i18n,');
    expect(ORIGINAL).toContain('    darkMode: {');
    expect(ORIGINAL).toContain('@vueless/storybook-dark-mode');
  });

  test('produces a definePreview default export from the framework package', () => {
    expect(result.changed).toBe(true);
    expect(result.source).toContain(
      "import {definePreview} from '@storybook/react-vite';"
    );
    expect(result.source).toContain('export default definePreview({');
    expect(result.source).not.toContain('Preview = {');
    expect(result.source).not.toContain('export default preview;');
  });

  test('wires msw as addonMsw() and drops every mswLoader', () => {
    expect(result.source).toContain(
      "import addonMsw from 'msw-storybook-addon';"
    );
    expect(result.source).toContain('addonMsw(),');
    expect(result.source).not.toContain('mswLoader');
    expect(result.source).not.toContain('msw-storybook-addon/csf3');
  });

  test('wires i18next through definePreviewAddon<AddonTypes>', () => {
    expect(result.source).toContain(
      "import storybookReactI18next from 'storybook-react-i18next/preview';"
    );
    expect(result.source).toContain(
      "import type {AddonTypes} from 'storybook/internal/csf';"
    );
    expect(result.source).toContain(
      "import {definePreviewAddon} from 'storybook/internal/csf';"
    );
    expect(result.source).toContain(
      'definePreviewAddon<AddonTypes>(storybookReactI18next),'
    );
  });

  test('wires a11y from its parameter and keeps the locale loader', () => {
    expect(result.source).toContain(
      "import addonA11y from '@storybook/addon-a11y';"
    );
    expect(result.source).toContain('addonA11y(),');
    expect(result.source).toContain('  loaders: [\n    async ({globals}) => {');
  });

  test('carries parameters.darkMode over and writes no dark-mode addon', () => {
    expect(result.source).toContain('    darkMode: {');
    expect(result.source).not.toContain('storybook-dark-mode');
  });

  test('reports no unknown addon', () => {
    expect(result.unknownAddons).toEqual([]);
  });

  test('feeding its own output back in changes nothing', () => {
    const again = rewirePreview(ts, result.source);

    expect(again.source).toBe(result.source);
    expect(again.changed).toBe(false);
  });
});

describe('rewirePreview', () => {
  test('keeps an unknown loader and decorator and reports an unknown addon', () => {
    const source = `import type {Preview} from '@storybook/react';
import {withThemeByClassName} from '@storybook/addon-themes';
import {mswLoader} from 'msw-storybook-addon';
import {seedLoader} from './seed';

const preview = {
  decorators: [withThemeByClassName({themes: {dark: 'dark'}})],
  loaders: [mswLoader, seedLoader],
} satisfies Preview;

export default preview;
`;

    const result = rewirePreview(ts, source);

    expect(result.source).toBe(`import {definePreview} from '@storybook/react';
import addonMsw from 'msw-storybook-addon';
import {withThemeByClassName} from '@storybook/addon-themes';
import {seedLoader} from './seed';

export default definePreview({
  decorators: [withThemeByClassName({themes: {dark: 'dark'}})],
  loaders: [seedLoader],
  addons: [
    addonMsw(),
  ],
});
`);
    expect(result.unknownAddons).toEqual(['@storybook/addon-themes']);
  });

  test('a preview with no i18next gets no i18next addon', () => {
    const source = `import type {Preview} from '@storybook/react-vite';
import {mswLoader} from 'msw-storybook-addon/csf3';
import a11y from './a11y';

const preview: Preview = {
  // msw resolves every handler before the story renders.
  loaders: [mswLoader()],
  parameters: {
    a11y,
    layout: 'fullscreen',
  },
};

export default preview;
`;

    const result = rewirePreview(ts, source);

    expect(result.source).toBe(`import addonA11y from '@storybook/addon-a11y';
import {definePreview} from '@storybook/react-vite';
import addonMsw from 'msw-storybook-addon';
import a11y from './a11y';

export default definePreview({
  parameters: {
    a11y,
    layout: 'fullscreen',
  },
  addons: [
    addonA11y(),
    addonMsw(),
  ],
});
`);
    expect(result.source).not.toMatch(/i18n/iu);
  });

  test('a definePreview preview is returned unchanged', () => {
    const source = `import {definePreview} from '@storybook/react-vite';

export default definePreview({parameters: {layout: 'centered'}});
`;

    expect(rewirePreview(ts, source)).toEqual({
      changed: false,
      source,
      unknownAddons: [],
    });
  });
});
