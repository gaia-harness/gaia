import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {compareBytes} from './markdown.js';
import {INVENTORY_ONLY_RULES, RULE_CATALOG} from './rules/index.js';
import {redactDeep} from './secrets.js';

type RuleListing = {
  aliases: readonly string[];
  applies_to: readonly string[];
  category: string;
  detection: string;
  inventory_only?: true;
  models?: readonly string[];
  rule_id: string;
  severity: string;
};

/** The catalog plus the inventory-only rules, sorted by id. */
export const listRules = (): RuleListing[] => {
  /* eslint-disable perfectionist/sort-objects -- the printed key order is part of the listing contract */
  const graded: RuleListing[] = RULE_CATALOG.map((rule) => ({
    rule_id: rule.ruleId,
    category: rule.category,
    severity: rule.severity,
    applies_to: rule.appliesTo,
    detection: rule.detection,
    aliases: rule.aliases ?? [],
    ...(rule.models === undefined ? {} : {models: rule.models}),
  }));
  const inventoryOnly: RuleListing[] = INVENTORY_ONLY_RULES.map((rule) => ({
    rule_id: rule.ruleId,
    category: rule.category,
    severity: rule.severity,
    applies_to: rule.appliesTo,
    detection: rule.detection,
    aliases: rule.aliases,
    inventory_only: true,
  }));
  /* eslint-enable perfectionist/sort-objects */

  const everything = [...graded, ...inventoryOnly];

  return everything.toSorted((a, b) => compareBytes(a.rule_id, b.rule_id));
};

/** `gaia fitness rules [--json]`: JSON is the only format. */
export const run = (args: readonly string[]): number => {
  const unknown = args.find((argument) => argument !== '--json');

  if (unknown !== undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown argument: ${unknown}`,
      subcommand: 'fitness rules',
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }

  process.stdout.write(`${JSON.stringify(redactDeep(listRules()), null, 2)}\n`);

  return EXIT_CODES.OK;
};
