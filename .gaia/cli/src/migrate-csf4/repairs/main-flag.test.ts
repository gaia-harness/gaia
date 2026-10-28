import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {setTestSyntaxFlag} from './index.js';

const COMMENT = `// The preview inlines no environment values: give a story the values it
// needs as args instead.
`;

const SHAPES = {
  'a defineMain call': `${COMMENT}
import {defineMain} from '@storybook/react-vite/node';

export default defineMain({
  features: {},
  framework: '@storybook/react-vite',
});
`,
  'a directly exported object': `${COMMENT}
import type {StorybookConfig} from '@storybook/react-vite';

export default {
  // Stories live beside their components.
  stories: ['../app/**/*.stories.tsx'],
  framework: '@storybook/react-vite',
} satisfies StorybookConfig;
`,
  'a StorybookConfig bound to a const': `import type {StorybookConfig} from '@storybook/react-vite';

${COMMENT}
const config: StorybookConfig = {
  addons: ['@vueless/storybook-dark-mode'],

  features: {
    backgrounds: false,
    experimentalDocgenServer: true,
  },

  framework: '@storybook/react-vite',
};

export default config;
`,
};

describe.each(Object.entries(SHAPES))(
  'setTestSyntaxFlag on %s',
  (_shape, source) => {
    const result = setTestSyntaxFlag(ts, source);

    test('turns experimentalTestSyntax on in features', () => {
      expect(result.changed).toBe(true);
      expect(result.source).toMatch(
        /features: \{[^}]*experimentalTestSyntax: true[^}]*\}/u
      );
    });

    test('keeps the opening comment byte-identical', () => {
      expect(result.source).toContain(COMMENT);
      expect(result.source.indexOf(COMMENT)).toBe(source.indexOf(COMMENT));
    });

    test('feeding its own output back in changes nothing', () => {
      const again = setTestSyntaxFlag(ts, result.source);

      expect(again).toEqual({changed: false, source: result.source});
    });
  }
);

describe('setTestSyntaxFlag', () => {
  test('adds the flag beside experimentalDocgenServer and leaves it untouched', () => {
    const source = SHAPES['a StorybookConfig bound to a const'];

    expect(setTestSyntaxFlag(ts, source).source).toBe(
      source.replace(
        '    experimentalDocgenServer: true,\n',
        '    experimentalDocgenServer: true,\n    experimentalTestSyntax: true,\n'
      )
    );
  });

  test('creates features when the main has none', () => {
    const source = SHAPES['a directly exported object'];

    expect(setTestSyntaxFlag(ts, source).source).toContain(
      "  framework: '@storybook/react-vite',\n  features: {experimentalTestSyntax: true},\n}"
    );
  });

  test('an unrecognized main shape is returned unchanged', () => {
    const source = 'module.exports = {stories: []};\n';

    expect(setTestSyntaxFlag(ts, source)).toEqual({changed: false, source});
  });
});
