import {
  entryPath,
  entryReason,
  entryRuleId,
  FITNESS_CONFIG_PATH,
  interpretConfigFile,
} from '../config.js';
import type {RuleContext, SettingsFile} from '../context.js';
import {lineOf} from '../markdown.js';
import type {RawFinding, RuleDefinition} from '../types.js';

const entriesOf = (file: SettingsFile): readonly unknown[] => {
  const interpreted = interpretConfigFile(file);

  return interpreted.ok ? interpreted.entries : [];
};

/** The line of the entry's `path` string, else of its `rule_id`, else 1. */
const entryLine = (file: SettingsFile, entry: unknown): number => {
  const index = [entryPath(entry), entryRuleId(entry)]
    .filter((value) => value !== undefined)
    .map((value) => file.text.indexOf(JSON.stringify(value)))
    .find((position) => position !== -1);

  return index === undefined ? 1 : lineOf(file.text, index);
};

const describeEntry = (entry: unknown): string => {
  const ruleId = entryRuleId(entry);
  const entryFile = entryPath(entry);

  return ruleId !== undefined && entryFile !== undefined ?
      `${ruleId} on ${entryFile}`
    : 'an entry missing rule_id or path';
};

const parseCheck = (context: RuleContext): readonly RawFinding[] => {
  const {fitnessConfig} = context;

  if (fitnessConfig === undefined) return [];

  const interpreted = interpretConfigFile(fitnessConfig);

  if (interpreted.ok) return [];

  return [
    {
      file: FITNESS_CONFIG_PATH,
      line: 1,
      message: `${FITNESS_CONFIG_PATH} cannot be read: ${interpreted.error}. No suppression applies until it does.`,
      remediation:
        'Make the file a JSON object with "version": 1 and an "ignore" list of {rule_id, path, reason} entries.',
    },
  ];
};

const noReasonCheck = (context: RuleContext): readonly RawFinding[] => {
  const {fitnessConfig} = context;

  if (fitnessConfig === undefined) return [];

  return entriesOf(fitnessConfig)
    .filter((entry) => entryReason(entry) === undefined)
    .map((entry) => ({
      file: FITNESS_CONFIG_PATH,
      line: entryLine(fitnessConfig, entry),
      message: `Suppression for ${describeEntry(entry)} has no reason, so it is not applied.`,
      remediation:
        'Add a "reason" saying why the finding is acceptable, or delete the entry.',
    }));
};

const staleCheck = (context: RuleContext): readonly RawFinding[] => {
  const {allTrackedPaths, files, fitnessConfig, knownRuleIds} = context;

  if (fitnessConfig === undefined) return [];

  const knownPaths = new Set([
    ...allTrackedPaths,
    ...files.map((file) => file.path),
  ]);

  return entriesOf(fitnessConfig).flatMap((entry) => {
    const ruleId = entryRuleId(entry);
    const entryFile = entryPath(entry);
    const problems: string[] = [];

    if (ruleId === undefined || !knownRuleIds.has(ruleId)) {
      problems.push('names no known rule');
    }

    if (entryFile === undefined || !knownPaths.has(entryFile)) {
      problems.push('matches no discovered file');
    }

    if (problems.length === 0) return [];

    return [
      {
        file: FITNESS_CONFIG_PATH,
        line: entryLine(fitnessConfig, entry),
        message: `Suppression for ${describeEntry(entry)} ${problems.join(' and ')}, so it can never apply.`,
        remediation:
          'Correct the rule_id or path, or delete the entry if the file or rule is gone.',
      },
    ];
  });
};

export const FITNESS_CONFIG_RULES: readonly RuleDefinition[] = [
  {
    appliesTo: ['fitness-config'],
    category: 'settings',
    check: noReasonCheck,
    detection:
      'A suppression entry in the fitness config has no reason, or an empty one; the entry is not applied.',
    ruleId: 'settings.fitness-config.no-reason',
    severity: 'warning',
  },
  {
    appliesTo: ['fitness-config'],
    category: 'settings',
    check: parseCheck,
    detection:
      'The fitness config is not valid JSON, or its version is not 1; no suppression applies.',
    ruleId: 'settings.fitness-config.parse',
    severity: 'error',
  },
  {
    appliesTo: ['fitness-config'],
    category: 'settings',
    check: staleCheck,
    detection:
      'A suppression entry names a rule id that does not exist or a path that matches no discovered file.',
    ruleId: 'settings.fitness-config.stale',
    severity: 'warning',
  },
];
