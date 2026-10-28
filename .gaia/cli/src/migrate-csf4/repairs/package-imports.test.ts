import {describe, expect, test} from 'vitest';
import {ensurePreviewImportsSubpath} from './index.js';

describe('ensurePreviewImportsSubpath', () => {
  test('creates imports before scripts, keeping the rest byte-identical', () => {
    const text = `{
  "name": "frontend",
  "private": true,
  "scripts": {
    "dev": "react-router dev"
  }
}
`;

    const result = ensurePreviewImportsSubpath(text);

    expect(result).toEqual({
      changed: true,
      text: `{
  "name": "frontend",
  "private": true,
  "imports": {
    "#.storybook/preview": "./.storybook/preview.ts"
  },
  "scripts": {
    "dev": "react-router dev"
  }
}
`,
    });
  });

  test('adds the entry to an existing imports object', () => {
    const text = `{
    "name": "frontend",
    "imports": {
        "#server/*": "./server/*.ts"
    }
}
`;

    expect(ensurePreviewImportsSubpath(text).text).toBe(`{
    "name": "frontend",
    "imports": {
        "#server/*": "./server/*.ts",
        "#.storybook/preview": "./.storybook/preview.ts"
    }
}
`);
  });

  test('creates imports at the end when there are no scripts', () => {
    const text = '{\n  "name": "frontend"\n}\n';

    expect(ensurePreviewImportsSubpath(text).text).toBe(
      '{\n  "name": "frontend",\n  "imports": {\n    "#.storybook/preview": "./.storybook/preview.ts"\n  }\n}\n'
    );
  });

  test('feeding its own output back in changes nothing', () => {
    const {text} = ensurePreviewImportsSubpath('{\n  "name": "frontend"\n}\n');

    expect(ensurePreviewImportsSubpath(text)).toEqual({changed: false, text});
  });

  test('a conflicting existing value is left alone', () => {
    const text =
      '{\n  "imports": {\n    "#.storybook/preview": "./.storybook/preview.tsx"\n  }\n}\n';

    expect(ensurePreviewImportsSubpath(text)).toEqual({changed: false, text});
  });
});
