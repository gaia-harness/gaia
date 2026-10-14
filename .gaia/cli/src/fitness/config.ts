import {readFileSync, realpathSync} from 'node:fs';
import path from 'node:path';
import type {SettingsFile} from './context.js';
import type {Finding, RuleDefinition, SuppressedFinding} from './types.js';

export const FITNESS_CONFIG_PATH = '.claude/gaia-fitness.json';

/** The `file` of a finding about a `--config` file, which may live outside the root. */
export const CONFIG_PLACEHOLDER = '<config>';

export const CONFIG_RULE_PREFIX = 'settings.fitness-config.';

export const CONFIG_PARSE_RULE_ID = 'settings.fitness-config.parse';

export type ConfigLoad =
  {entries: readonly unknown[]; ok: true} | {error: string; ok: false};

export type SuppressionEntry = {
  path: string;
  reason: string;
  ruleId: string;
};

/** Validates the shape of a parsed config; the version and the `ignore` list. */
export const interpretConfig = (parsed: unknown): ConfigLoad => {
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return {error: 'the file must hold a JSON object', ok: false};
  }

  const {ignore, version} = parsed as {ignore?: unknown; version?: unknown};

  if (version !== 1) {
    return {error: '"version" must be the number 1', ok: false};
  }

  if (ignore === undefined) return {entries: [], ok: true};

  if (!Array.isArray(ignore)) {
    return {error: '"ignore" must be a list', ok: false};
  }

  return {entries: ignore as unknown[], ok: true};
};

/** The config as the rules and the suppressor see it: shape-checked once. */
export const interpretConfigFile = (file: SettingsFile): ConfigLoad =>
  file.parseError === undefined ?
    interpretConfig(file.parsed)
  : {error: `not valid JSON (${file.parseError})`, ok: false};

const stringField = (entry: unknown, key: string): string | undefined => {
  if (entry === null || typeof entry !== 'object') return undefined;

  const value = (entry as Record<string, unknown>)[key];

  return typeof value === 'string' ? value : undefined;
};

export const entryRuleId = (entry: unknown): string | undefined =>
  stringField(entry, 'rule_id');

export const entryPath = (entry: unknown): string | undefined =>
  stringField(entry, 'path');

export const entryReason = (entry: unknown): string | undefined => {
  const reason = stringField(entry, 'reason');

  return reason === undefined || reason.trim() === '' ? undefined : reason;
};

/** Keeps only the entries that can suppress: all three fields present and a reason given. */
export const appliedEntries = (
  entries: readonly unknown[]
): SuppressionEntry[] =>
  entries.flatMap((entry) => {
    const ruleId = entryRuleId(entry);
    const entryFile = entryPath(entry);
    const reason = entryReason(entry);

    return (
        ruleId === undefined ||
          entryFile === undefined ||
          reason === undefined ||
          ruleId === ''
      ) ?
        []
      : [{path: entryFile, reason, ruleId}];
  });

export type ConfigSource = {
  entries: readonly SuppressionEntry[];
  /** Set when a `--config` file could not be loaded. */
  loadError: string | undefined;
};

const NO_ENTRIES: ConfigSource = {entries: [], loadError: undefined};

const sourceOf = (interpreted: ConfigLoad): ConfigSource =>
  interpreted.ok ?
    {entries: appliedEntries(interpreted.entries), loadError: undefined}
  : {entries: [], loadError: interpreted.error};

/**
 * Chooses the file whose entries apply. `--config` replaces the discovered
 * file; a missing `--config` file means no suppressions and no finding. The
 * discovered file's own problems are reported by the config rules, not here.
 */
export const loadSuppressionSource = (input: {
  configPath: string | undefined;
  discovered: SettingsFile | undefined;
  root: string;
}): ConfigSource => {
  const fromDiscovered = (): ConfigSource => {
    if (input.discovered === undefined) return NO_ENTRIES;

    const interpreted = interpretConfigFile(input.discovered);

    return interpreted.ok ? sourceOf(interpreted) : NO_ENTRIES;
  };

  if (input.configPath === undefined) return fromDiscovered();

  const supplied = path.resolve(input.configPath);
  let suppliedReal: string;

  try {
    suppliedReal = realpathSync(supplied);
  } catch {
    return NO_ENTRIES;
  }

  try {
    const discoveredReal = realpathSync(
      path.join(input.root, FITNESS_CONFIG_PATH)
    );

    if (discoveredReal === suppliedReal) return fromDiscovered();
  } catch {
    // The root has no config of its own, so the supplied file stands alone.
  }

  let text: string;

  try {
    text = readFileSync(suppliedReal, 'utf8');
  } catch {
    return {entries: [], loadError: 'the file could not be read'};
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(text) as unknown;
  } catch {
    return {entries: [], loadError: 'the file is not valid JSON'};
  }

  const interpreted = interpretConfig(parsed);

  return sourceOf(interpreted);
};

/** Maps every rule id and alias to the rule's own id. */
export const canonicalRuleIds = (
  catalog: readonly RuleDefinition[]
): Map<string, string> => {
  const canonical = new Map<string, string>();

  for (const rule of catalog) {
    canonical.set(rule.ruleId, rule.ruleId);
    for (const alias of rule.aliases ?? []) canonical.set(alias, rule.ruleId);
  }

  return canonical;
};

/**
 * Splits graded findings into kept and suppressed. A finding the config files
 * raise is never suppressible, so a config cannot silence its own errors.
 */
export const applySuppressions = (
  findings: readonly Finding[],
  entries: readonly SuppressionEntry[],
  canonical: ReadonlyMap<string, string>
): {kept: Finding[]; suppressed: SuppressedFinding[]} => {
  const kept: Finding[] = [];
  const suppressed: SuppressedFinding[] = [];

  for (const finding of findings) {
    const entry =
      finding.rule_id.startsWith(CONFIG_RULE_PREFIX) ?
        undefined
      : entries.find(
          (candidate) =>
            candidate.path === finding.file &&
            (canonical.get(candidate.ruleId) ?? candidate.ruleId) ===
              finding.rule_id
        );

    if (entry === undefined) kept.push(finding);
    else suppressed.push({...finding, fixable: false, reason: entry.reason});
  }

  return {kept, suppressed};
};
