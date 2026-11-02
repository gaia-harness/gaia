import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {readCheckoutFile} from './repairs-fixture.js';
import {
  capturePreCodemodFacts,
  ensurePreviewImportsSubpath,
  repairStoryFile,
  rewirePreview,
  setTestSyntaxFlag,
} from './index.js';

// GAIA's own converted Storybook files are the target form, so every repair
// must pass them through byte-identical: that is what makes a re-run over an
// already-migrated project change nothing.
describe("GAIA's converted Storybook files pass through unchanged", () => {
  test('the preview', () => {
    const source = readCheckoutFile('apps/web/.storybook/preview.ts');

    expect(rewirePreview(ts, source)).toEqual({
      changed: false,
      source,
      unknownAddons: [],
    });
  });

  test('the main', () => {
    const source = readCheckoutFile('apps/web/.storybook/main.ts');

    expect(setTestSyntaxFlag(ts, source)).toEqual({changed: false, source});
  });

  test('the package.json', () => {
    const text = readCheckoutFile('apps/web/package.json');

    expect(ensurePreviewImportsSubpath(text)).toEqual({changed: false, text});
  });

  test.each([
    'apps/web/app/components/errors/error-stack/tests/index.stories.tsx',
    'apps/web/app/components/form/tests/composed-form.stories.tsx',
    'apps/web/app/components/ui/tests/toast.stories.tsx',
  ])('the story %s', (relativePath) => {
    const source = readCheckoutFile(relativePath);
    const facts = capturePreCodemodFacts(ts, source, relativePath);

    expect(repairStoryFile(ts, source, source, facts, relativePath)).toEqual({
      notes: [],
      source,
    });
  });
});
