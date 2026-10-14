import type {FixtureMap, FixturePair} from '../types.js';
import {AUTHORING_FIXTURES} from './authoring.fixtures.js';
import {CLAUDEMD_FIXTURES} from './claudemd.fixtures.js';
import {FITNESS_CONFIG_FIXTURES} from './fitness-config.fixtures.js';
import {FRONTMATTER_FIXTURES} from './frontmatter.fixtures.js';
import {HOOKS_FIXTURES} from './hooks.fixtures.js';
import {PROMPT_FIXTURES} from './prompt.fixtures.js';
import {RULES_FIXTURES} from './rules.fixtures.js';
import {SETTINGS_FIXTURES} from './settings.fixtures.js';
import {WIKI_FIXTURES} from './wiki.fixtures.js';

const merge = (maps: readonly FixtureMap[]): FixtureMap => {
  const merged: Record<string, FixturePair> = {};

  for (const map of maps) {
    for (const [ruleId, pair] of Object.entries(map)) {
      // A silent overwrite would let one family's fixture stand in for another's.
      if (Object.hasOwn(merged, ruleId)) {
        throw new Error(`duplicate fixture for rule ${ruleId}`);
      }
      merged[ruleId] = pair;
    }
  }

  return merged;
};

/** Every family's red and green fixtures, keyed by rule id. */
export const ALL_FIXTURES: FixtureMap = merge([
  HOOKS_FIXTURES,
  SETTINGS_FIXTURES,
  FRONTMATTER_FIXTURES,
  RULES_FIXTURES,
  CLAUDEMD_FIXTURES,
  AUTHORING_FIXTURES,
  PROMPT_FIXTURES,
  WIKI_FIXTURES,
  FITNESS_CONFIG_FIXTURES,
]);
