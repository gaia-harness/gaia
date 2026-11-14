// Runs in the node project.
// The rule itself is tested in @gaia-harness/lint; this asserts the app passes
// the preset its nodeFiles globs, so the rule is off where code runs in Node
// (CSS is undefined and its CSS.escape autofix would crash) and on in browser
// code.
import type {Linter} from 'eslint';
import {ESLint} from 'eslint';
import {describe, expect, test} from 'vitest';
import path from 'node:path';

const frontendDirectory = path.resolve(import.meta.dirname, '../..');

// Building an ESLint instance loads the config's plugins, which can outlast
// the node project's default test timeout under a full-suite run.
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
    ['app/utils/tests/example.test.ts', 0],
    ['test/example.test.ts', 0],
    ['app/sessions.server/example.ts', 0],
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
