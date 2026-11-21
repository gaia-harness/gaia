// Runs in the node project.
// The rule itself is tested in @gaia-harness/lint; this pins the app's resolved
// lint config (the app's nodeFiles wiring, plus the preset's Node exemption for
// Playwright specs and .server code and its browser-callback rule for specs),
// so the rule is off where code runs in Node (CSS is undefined and its
// CSS.escape autofix would crash) and on in browser code.
import type {Linter} from 'eslint';
import {ESLint} from 'eslint';
import {describe, expect, test} from 'vitest';
import path from 'node:path';

const frontendDirectory = path.resolve(import.meta.dirname, '../..');

// Building an ESLint instance loads the config's plugins, which can outlast
// the node project's testTimeout (coldImportTestTimeout in vitest.config.ts)
// under a full-suite run, hence each case's own timeout below.
const resolveRuleSeverityForFile = async (
  relativePath: string,
  ruleId = 'unicorn/require-css-escape'
) => {
  const config = (await new ESLint({
    cwd: frontendDirectory,
  }).calculateConfigForFile(
    path.join(frontendDirectory, relativePath)
  )) as Linter.Config;
  const entry = config.rules?.[ruleId];

  return Array.isArray(entry) ? entry[0] : entry;
};

describe('require-css-escape rules resolve to the right severity per file kind', () => {
  test.each([
    ['unicorn/require-css-escape', 'app/utils/tests/example.test.ts', 0],
    ['unicorn/require-css-escape', 'test/example.test.ts', 0],
    ['unicorn/require-css-escape', 'app/sessions.server/example.ts', 0],
    ['unicorn/require-css-escape', '.playwright/e2e/example.spec.ts', 0],
    ['unicorn/require-css-escape', 'app/hooks/tests/use-example.test.ts', 2],
    ['unicorn/require-css-escape', 'app/root.tsx', 2],
    [
      'browser-callback-css-escape/require-css-escape',
      '.playwright/e2e/example.spec.ts',
      2,
    ],
  ])(
    'resolves %s for %s to severity %s',
    async (ruleId, relativePath, severity) => {
      expect(await resolveRuleSeverityForFile(relativePath, ruleId)).toBe(
        severity
      );
    },
    60_000
  );
});
