import {compareBytes} from '../markdown.js';
import type {RuleDefinition, Severity} from '../types.js';
import {AUTHORING_RULES} from './authoring.js';
import {CLAUDEMD_RULES} from './claudemd.js';
import {FITNESS_CONFIG_RULES} from './fitness-config.js';
import {FRONTMATTER_RULES} from './frontmatter.js';
import {HOOKS_RULES} from './hooks.js';
import {PROMPT_RULES} from './prompt.js';
import {RULES_RULES} from './rules.js';
import {SETTINGS_RULES} from './settings.js';
import {WIKI_RULES} from './wiki.js';

/** Every graded rule, sorted by id. The one list `check` runs. */
const ALL_RULES: readonly RuleDefinition[] = [
  ...HOOKS_RULES,
  ...SETTINGS_RULES,
  ...FRONTMATTER_RULES,
  ...RULES_RULES,
  ...CLAUDEMD_RULES,
  ...AUTHORING_RULES,
  ...PROMPT_RULES,
  ...WIKI_RULES,
  ...FITNESS_CONFIG_RULES,
];

export const RULE_CATALOG: readonly RuleDefinition[] = ALL_RULES.toSorted(
  (a, b) => compareBytes(a.ruleId, b.ruleId)
);

export type InventoryOnlyRule = {
  aliases: readonly string[];
  appliesTo: readonly ['memory'];
  category: 'memory';
  detection: string;
  ruleId: string;
  severity: Severity;
};

/**
 * Rules that only `inventory` reports. They are listed by `rules` so the
 * catalog is complete, but `check` never runs them and they carry no check.
 */
export const INVENTORY_ONLY_RULES: readonly InventoryOnlyRule[] = [
  {
    aliases: [],
    appliesTo: ['memory'],
    category: 'memory',
    detection:
      'A memory file names a repo path that no longer exists in the project.',
    ruleId: 'memory.dead-path',
    severity: 'warning',
  },
];
