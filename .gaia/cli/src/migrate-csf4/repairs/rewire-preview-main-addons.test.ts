import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {readCheckoutFile, readMigrationFixture} from './repairs-fixture.js';
import {mainAddonSpecifiers, rewirePreview} from './index.js';

const TARGET = readCheckoutFile('frontend/.storybook/preview.ts');
const GAIA_MAIN_ADDONS = mainAddonSpecifiers(
  ts,
  readCheckoutFile('frontend/.storybook/main.ts')
);

/** The block of `source` from `first` through the line starting `last`. */
const block = (source: string, first: string, last: string): string => {
  const start = source.indexOf(first);
  const lineEnd = source.indexOf('\n', source.indexOf(last, start));

  return source.slice(start, lineEnd);
};

const MINIMAL = `import type {Preview} from '@storybook/react-vite';

const preview: Preview = {
  parameters: {layout: 'fullscreen'},
};

export default preview;
`;

describe("rewirePreview over GAIA's CSF3 preview with GAIA's main addons", () => {
  const result = rewirePreview(
    ts,
    readMigrationFixture('preview.ts.csf3'),
    GAIA_MAIN_ADDONS
  );

  test('imports the addons in the target preview order', () => {
    expect(result.source).toContain(
      "import addonLinks from '@storybook/addon-links';"
    );
    expect(result.source).toContain(
      block(
        TARGET,
        "import addonA11y from '@storybook/addon-a11y';",
        'import {definePreviewAddon}'
      )
    );
  });

  test('wires addonLinks() between a11y and msw, as the target preview does', () => {
    const addons = block(TARGET, '  addons: [', '    addonMsw(),');

    expect(addons).toContain('addonLinks(),');
    expect(result.source).toContain(addons);
  });

  test('wires no vitest or dark-mode addon and reports nothing', () => {
    expect(result.source).not.toMatch(/vitest|dark-mode/u);
    expect(result.unknownAddons).toEqual([]);
  });

  test('feeding its own output back in with the same main changes nothing', () => {
    expect(rewirePreview(ts, result.source, GAIA_MAIN_ADDONS)).toEqual({
      changed: false,
      source: result.source,
      unknownAddons: [],
    });
  });

  test("GAIA's CSF4 preview passes through byte-identical", () => {
    expect(rewirePreview(ts, TARGET, GAIA_MAIN_ADDONS)).toEqual({
      changed: false,
      source: TARGET,
      unknownAddons: [],
    });
  });
});

describe('rewirePreview with main addons', () => {
  test('without main addons, an addon only main lists is not wired', () => {
    const result = rewirePreview(ts, MINIMAL);

    expect(result.source).not.toContain('addons:');
    expect(result.source).not.toContain('addonLinks');
  });

  test('an object entry naming the links addon in main wires it', () => {
    const main = `export default {addons: [{name: '@storybook/addon-links', options: {}}]};\n`;
    const result = rewirePreview(ts, MINIMAL, mainAddonSpecifiers(ts, main));

    expect(result.source).toBe(`import addonLinks from '@storybook/addon-links';
import {definePreview} from '@storybook/react-vite';

export default definePreview({
  parameters: {layout: 'fullscreen'},
  addons: [
    addonLinks(),
  ],
});
`);
  });

  test('main-listed a11y, i18next and msw are wired without a preview sign', () => {
    const result = rewirePreview(ts, MINIMAL, [
      'msw-storybook-addon',
      'storybook-react-i18next',
      '@storybook/addon-a11y',
    ]);

    expect(result.source).toContain('    addonA11y(),\n');
    expect(result.source).toContain(
      '    definePreviewAddon<AddonTypes>(storybookReactI18next),\n    addonMsw(),\n'
    );
  });

  test('the docs addon is wired as addonDocs(), as the codemod syncs it', () => {
    const result = rewirePreview(ts, MINIMAL, [
      '@storybook/addon-links',
      '@storybook/addon-docs',
      '@storybook/addon-a11y',
    ]);

    expect(result.source).toContain(
      "import addonA11y from '@storybook/addon-a11y';\nimport addonDocs from '@storybook/addon-docs';\nimport addonLinks from '@storybook/addon-links';\n"
    );
    expect(result.source).toContain(
      '    addonA11y(),\n    addonDocs(),\n    addonLinks(),\n'
    );
    expect(result.unknownAddons).toEqual([]);
  });

  test('an unknown main addon is reported, not wired; the vitest addon is neither', () => {
    const result = rewirePreview(ts, MINIMAL, [
      '@storybook/addon-themes',
      '@storybook/addon-vitest',
      './local-addon',
    ]);

    expect(result.unknownAddons).toEqual(['@storybook/addon-themes']);
    expect(result.source).not.toMatch(/themes|vitest|addons:/iu);
  });

  test('an addon both imported and listed in main is reported once', () => {
    const source = MINIMAL.replace(
      '\n\nconst',
      "\nimport {withThemeByClassName} from '@storybook/addon-themes';\n\nconst"
    );

    expect(
      rewirePreview(ts, source, ['@storybook/addon-themes']).unknownAddons
    ).toEqual(['@storybook/addon-themes']);
  });

  test('a listed dark-mode addon stays out of the preview', () => {
    const result = rewirePreview(ts, MINIMAL, ['@vueless/storybook-dark-mode']);

    expect(result.source).not.toContain('dark-mode');
    expect(result.unknownAddons).toEqual([]);
  });
});
