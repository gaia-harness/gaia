// Runs in the node project.
// The rule itself is tested in @gaia-harness/lint; this asserts the resolved
// project config turns it off where code runs in Node, where CSS is undefined
// and its CSS.escape autofix would crash, and keeps it on for browser code.
import type {Linter} from 'eslint';
import {ESLint} from 'eslint';
import {describe, expect, test} from 'vitest';
import path from 'node:path';

const frontendDirectory = path.resolve(import.meta.dirname, '../..');

// Each case builds a fresh ESLint instance and loads the config's plugins,
// which can outlast the node project's test timeout (coldImportTestTimeout in
// vitest.config.ts) under a full-suite run.
const resolveRuleSeverityForFile = async (relativePath: string) => {
  const config = (await new ESLint({
    cwd: frontendDirectory,
  }).calculateConfigForFile(
    path.join(frontendDirectory, relativePath)
  )) as Linter.Config;
  const entry = config.rules?.['unicorn/require-css-escape'];

  return Array.isArray(entry) ? entry[0] : entry;
};

describe('unicorn/require-css-escape in the resolved project config', () => {
  test.each([
    ['.playwright/e2e/a11y-scan-settles.spec.ts', 0],
    ['test/playwright-html.test.ts', 0],
    ['app/utils/example.server.ts', 0],
    ['app/utils/tests/example.test.ts', 0],
    ['app/hooks/tests/use-example.test.ts', 2],
    ['app/root.tsx', 2],
  ])(
    'resolves %s to severity %s',
    async (relativePath, severity) => {
      expect(await resolveRuleSeverityForFile(relativePath)).toBe(severity);
    },
    60_000
  );
});
