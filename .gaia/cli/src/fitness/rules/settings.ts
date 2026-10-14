import type {RuleContext, SettingsFile} from '../context.js';
import {isRecord, lineOfJsonKey} from '../json.js';
import {lineOf} from '../markdown.js';
import {CREDENTIAL_PATTERNS, SECRET_KEY_PATTERN} from '../secrets.js';
import type {RawFinding, RuleDefinition} from '../types.js';

const LOCAL_SETTINGS_SUFFIX = '.claude/settings.local.json';

const PERMISSION_LISTS = ['allow', 'ask', 'deny'] as const;

const BARE_TOOL = /^[\w.]+$/;

const isLocal = (file: SettingsFile): boolean =>
  file.path === LOCAL_SETTINGS_SUFFIX ||
  file.path.endsWith(`/${LOCAL_SETTINGS_SUFFIX}`);

const validJsonCheck = (context: RuleContext): readonly RawFinding[] =>
  context.settingsFiles
    .filter((file) => file.parseError !== undefined)
    .map((file) => ({
      file: file.path,
      line: 1,
      message: `${file.path} is not valid JSON (${file.parseError ?? 'parse error'}), so Claude Code ignores every setting in it.`,
      remediation:
        'Fix the JSON syntax; a trailing comma or comment is enough.',
    }));

const isCredential = (value: string): boolean =>
  CREDENTIAL_PATTERNS.some((pattern) => value.search(pattern) !== -1);

/** The message names the key only: a finding must never echo any part of the value. */
const envSecretsCheck = (context: RuleContext): readonly RawFinding[] =>
  context.settingsFiles
    // The local file is gitignored and per machine, which is where a secret belongs.
    .filter((file) => !isLocal(file) && isRecord(file.parsed))
    .flatMap((file) => {
      const {env} = file.parsed as Record<string, unknown>;

      if (!isRecord(env)) return [];

      return Object.entries(env)
        .filter(
          ([key, value]) =>
            typeof value === 'string' &&
            value !== '' &&
            (isCredential(value) || SECRET_KEY_PATTERN.test(key))
        )
        .map(([key]) => ({
          file: file.path,
          line: lineOfJsonKey(file.text, key),
          message: `env.${key} holds a secret in a committed settings file.`,
          remediation:
            'Move the value to your shell environment or settings.local.json, and rotate it if it was ever pushed.',
        }));
    });

const permissionLists = (file: SettingsFile): Map<string, string[]> => {
  const lists = new Map<string, string[]>();

  if (!isRecord(file.parsed)) return lists;

  const {permissions} = file.parsed;

  if (!isRecord(permissions)) return lists;

  for (const name of PERMISSION_LISTS) {
    const list = permissions[name];

    if (Array.isArray(list)) {
      lists.set(
        name,
        list.filter((entry): entry is string => typeof entry === 'string')
      );
    }
  }

  return lists;
};

const toolOf = (entry: string): string => {
  const open = entry.indexOf('(');

  return open === -1 ? entry : entry.slice(0, open);
};

const bashSpecOf = (entry: string): string | undefined =>
  entry.startsWith('Bash(') && entry.endsWith(')') ?
    entry.slice('Bash('.length, -1)
  : undefined;

/** The entry that makes `entry` (at `position`) redundant, else undefined. */
const shadowOf = (
  entry: string,
  position: number,
  list: readonly string[]
): string | undefined => {
  if (list.indexOf(entry) < position) return `an earlier identical ${entry}`;

  const tool = toolOf(entry);

  if (tool !== entry && BARE_TOOL.test(tool) && list.includes(tool)) {
    return tool;
  }

  const spec = bashSpecOf(entry);

  if (spec === undefined) return undefined;

  return list.find((other) => {
    const otherSpec = bashSpecOf(other);

    if (!otherSpec?.endsWith(':*')) return false;
    if (other === entry) return false;

    const prefix = otherSpec.slice(0, -':*'.length);

    return spec === prefix || spec.startsWith(`${prefix} `);
  });
};

/** Line of the `occurrence`-th identical string at or after the list's key. */
const lineOfEntry = (
  file: SettingsFile,
  target: {entry: string; listName: string; occurrence: number}
): number => {
  const {entry, listName, occurrence} = target;
  let from = Math.max(file.text.indexOf(`"${listName}"`), 0);
  let found = -1;

  for (let count = 0; count <= occurrence; count += 1) {
    found = file.text.indexOf(JSON.stringify(entry), from);
    if (found === -1) return 1;
    from = found + 1;
  }

  return lineOf(file.text, found);
};

const redundantPermissionsCheck = (
  context: RuleContext
): readonly RawFinding[] =>
  context.settingsFiles.flatMap((file) =>
    [...permissionLists(file)].flatMap(([listName, list]) =>
      list.flatMap((entry, position) => {
        const shadow = shadowOf(entry, position, list);

        if (shadow === undefined) return [];

        const occurrence = list
          .slice(0, position)
          .filter((earlier) => earlier === entry).length;

        return [
          {
            file: file.path,
            line: lineOfEntry(file, {entry, listName, occurrence}),
            message: `permissions.${listName} entry ${entry} is redundant: ${shadow} already covers it.`,
            remediation: 'Delete the redundant entry.',
          },
        ];
      })
    )
  );

const localGitignoredCheck = (context: RuleContext): readonly RawFinding[] =>
  context.settingsFiles
    .filter(isLocal)
    .filter((file) => context.gitIgnored(file.path) === false)
    .map((file) => ({
      file: file.path,
      line: 1,
      message: `${file.path} is not covered by .gitignore, so a git add can commit your machine-local settings.`,
      remediation: `Add ${file.path} to .gitignore.`,
    }));

export const SETTINGS_RULES: readonly RuleDefinition[] = [
  {
    appliesTo: ['settings'],
    category: 'settings',
    check: envSecretsCheck,
    detection:
      'An env value in a committed settings file matches a known credential shape, or its key reads as a secret and its value is not empty.',
    ruleId: 'settings.env-secrets',
    severity: 'error',
  },
  {
    appliesTo: ['settings-local'],
    category: 'settings',
    check: localGitignoredCheck,
    detection:
      'settings.local.json exists in a git repository and git does not ignore it.',
    ruleId: 'settings.local-gitignored',
    severity: 'warning',
  },
  {
    appliesTo: ['settings', 'settings-local'],
    category: 'settings',
    check: redundantPermissionsCheck,
    detection:
      'Within one permissions list, an exact duplicate, a Tool(spec) entry shadowed by bare Tool, or a Bash(prefix ...) entry shadowed by Bash(prefix:*).',
    ruleId: 'settings.redundant-permissions',
    severity: 'info',
  },
  {
    appliesTo: ['settings', 'settings-local'],
    category: 'settings',
    check: validJsonCheck,
    detection: 'A linted settings file does not parse as JSON.',
    ruleId: 'settings.valid-json',
    severity: 'error',
    structural: true,
  },
];
