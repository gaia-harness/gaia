import {describe, expect, test} from 'vitest';
import {expectFixtureParity} from '../test-support.js';
import {ALL_FIXTURES} from './fixtures.js';
import {INVENTORY_ONLY_RULES, RULE_CATALOG} from './index.js';

// Every rule builds a red and a green scratch project (git init plus a classifier spawn), far past the default timeout.
const CATALOG_PARITY_TIMEOUT_MS = 60_000;

describe('rule catalog', () => {
  test(
    'every rule has a red fixture that fires it and a green fixture that does not',
    () => {
      expectFixtureParity(RULE_CATALOG, ALL_FIXTURES);
    },
    CATALOG_PARITY_TIMEOUT_MS
  );

  test('rule ids are unique and each starts with its category', () => {
    const ids = RULE_CATALOG.map((rule) => rule.ruleId);

    expect(new Set(ids).size).toBe(ids.length);

    for (const rule of RULE_CATALOG) {
      expect(rule.ruleId.split('.', 1)[0]).toBe(rule.category);
    }
  });

  test('no alias collides with a rule id or another alias', () => {
    const names = RULE_CATALOG.flatMap((rule) => [
      rule.ruleId,
      ...(rule.aliases ?? []),
    ]);

    expect(new Set(names).size).toBe(names.length);
  });

  test('the inventory-only rules are outside the catalog and have no fixture', () => {
    for (const rule of INVENTORY_ONLY_RULES) {
      expect(RULE_CATALOG.some((graded) => graded.ruleId === rule.ruleId)).toBe(
        false
      );
      expect(Object.hasOwn(ALL_FIXTURES, rule.ruleId)).toBe(false);
    }
  });
});
