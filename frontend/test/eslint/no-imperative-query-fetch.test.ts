// Runs in the node project.
// The rule itself is tested in @gaia-react/lint; this asserts the resolved
// project config still carries it beside the inherited entries.
import {ESLint} from 'eslint';
import {describe, expect, test} from 'vitest';
import path from 'node:path';

// The first lintText builds the type-aware TypeScript program for the whole
// project, which outlasts the default 5s timeout when the full suite runs.
describe(
  'no-imperative-query-fetch in the resolved project config',
  {
    timeout: 60_000,
  },
  () => {
    const frontendDirectory = path.resolve(import.meta.dirname, '../..');
    const filePath = path.join(frontendDirectory, 'app/root.tsx');
    const eslint = new ESLint({cwd: frontendDirectory});

    const collectRuleIdsFor = async (code: string) => {
      const [lintResult] = await eslint.lintText(code, {filePath});

      return lintResult.messages.map((message) => message.ruleId);
    };

    test('reports an imperative fetch', async () => {
      const ruleIds = await collectRuleIdsFor(
        'export const load = (queryClient: {fetchQuery: (o: unknown) => unknown}) => queryClient.fetchQuery({});\n'
      );

      expect(ruleIds).toContain(
        'no-imperative-query-fetch/no-imperative-query-fetch'
      );
    });

    test('keeps the inherited no-restricted-properties entries', async () => {
      const ruleIds = await collectRuleIdsFor(
        'export const value = Math.pow(2, 3);\n'
      );

      expect(ruleIds).toContain('no-restricted-properties');
    });

    test('keeps the inherited no-restricted-syntax selectors', async () => {
      const ruleIds = await collectRuleIdsFor(
        'export default function Example() {\n  return 1;\n}\n'
      );

      expect(ruleIds).toContain('no-restricted-syntax');
    });
  }
);
