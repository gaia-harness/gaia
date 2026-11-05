// Runs in the node project.
// The rule itself is tested in @gaia-harness/lint; this asserts the resolved
// project config still carries it beside the inherited entries.
import type {Linter} from 'eslint';
import {ESLint} from 'eslint';
import {beforeAll, describe, expect, test} from 'vitest';
import path from 'node:path';

const frontendDirectory = path.resolve(import.meta.dirname, '../..');
const filePath = path.join(frontendDirectory, 'app/root.tsx');

let rules: Partial<Linter.RulesRecord> = {};

// Resolving the config reads no source, so unlike linting it builds no
// TypeScript program and its cost does not grow with the project. Loading the
// config's plugins still takes several seconds, longer under a full-suite run,
// which the default 10s hook timeout does not cover.
beforeAll(async () => {
  const config = (await new ESLint({
    cwd: frontendDirectory,
  }).calculateConfigForFile(filePath)) as Linter.Config;

  rules = config.rules ?? {};
}, 60_000);

const optionsOf = (ruleId: string) => {
  const entry = rules[ruleId];

  return Array.isArray(entry) ? entry.slice(1) : [];
};

describe('no-imperative-query-fetch in the resolved project config', () => {
  test('enables the rule as an error', () => {
    expect(
      rules['no-imperative-query-fetch/no-imperative-query-fetch']
    ).toEqual([2]);
  });

  test.each([
    ['no-restricted-properties', {object: 'Math', property: 'pow'}],
    [
      'no-restricted-syntax',
      {selector: 'ExportDefaultDeclaration > FunctionDeclaration'},
    ],
  ])('keeps the inherited %s entries', (ruleId, entry) => {
    expect(optionsOf(ruleId)).toContainEqual(expect.objectContaining(entry));
  });
});
