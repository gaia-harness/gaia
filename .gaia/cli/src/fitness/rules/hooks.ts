import type {RuleContext, SettingsFile} from '../context.js';
import {isRecord, lineOfJsonKey} from '../json.js';
import {lineOf} from '../markdown.js';
import type {RawFinding, RuleDefinition} from '../types.js';
import type {ScriptReference} from './hook-command.js';
import {readScriptReference} from './hook-command.js';

/**
 * The events Claude Code documents. A closed list, so an unknown key is a
 * warning rather than an error: a newer Claude Code release may add an event
 * before this list does, and a typo should still surface.
 */
export const KNOWN_HOOK_EVENTS: ReadonlySet<string> = new Set([
  'ConfigChange',
  'CwdChanged',
  'Elicitation',
  'ElicitationResult',
  'FileChanged',
  'InstructionsLoaded',
  'Notification',
  'PermissionDenied',
  'PermissionRequest',
  'PostCompact',
  'PostToolUse',
  'PostToolUseFailure',
  'PreCompact',
  'PreToolUse',
  'SessionEnd',
  'SessionStart',
  'Setup',
  'Stop',
  'StopFailure',
  'SubagentStart',
  'SubagentStop',
  'TaskCompleted',
  'TaskCreated',
  'TeammateIdle',
  'UserPromptExpansion',
  'UserPromptSubmit',
  'WorktreeCreate',
  'WorktreeRemove',
]);

type HookEntry = {command: string; event: string; line: number};

const eventsOf = (file: SettingsFile): Record<string, unknown> => {
  if (!isRecord(file.parsed)) return {};

  const {hooks} = file.parsed;

  return isRecord(hooks) ? hooks : {};
};

/**
 * Every `hooks.<Event>[].hooks[].command`, with the line of its string. Each
 * command is searched for after the previous match under the same event, so
 * two identical commands report two lines.
 */
const hookEntriesOf = (file: SettingsFile): readonly HookEntry[] =>
  Object.entries(eventsOf(file)).flatMap(([event, groups]) => {
    if (!Array.isArray(groups)) return [];

    let cursor = Math.max(file.text.indexOf(JSON.stringify(event)), 0);

    return (groups as unknown[]).flatMap((group) => {
      const handlers = isRecord(group) ? group.hooks : undefined;

      if (!Array.isArray(handlers)) return [];

      return (handlers as unknown[]).flatMap((handler) => {
        const command = isRecord(handler) ? handler.command : undefined;

        if (typeof command !== 'string') return [];

        const found = file.text.indexOf(JSON.stringify(command), cursor);

        if (found !== -1) cursor = found + 1;

        return [
          {
            command,
            event,
            line: found === -1 ? 1 : lineOf(file.text, found),
          },
        ];
      });
    });
  });

export type HookRuleOptions = {
  /** Why the script behind a recognized root prefix cannot run, else undefined. */
  findScriptProblem?: (
    context: RuleContext,
    reference: ScriptReference,
    fromFile: string
  ) => string | undefined;
  /** Whether the reference resolves against the shell's current directory. */
  isUnanchored?: (reference: ScriptReference) => boolean;
};

const defaultFindScriptProblem = (
  context: RuleContext,
  reference: ScriptReference,
  fromFile: string
): string | undefined => {
  if (reference.kind !== 'anchored') return undefined;

  const resolved = context.resolve(fromFile, reference.remainder, 'root');

  if (resolved.status === 'invalid') return undefined;

  if (resolved.status === 'outside') {
    return `resolves outside the project (${reference.remainder})`;
  }

  if (!resolved.exists) return `does not exist (${resolved.relative})`;

  if (
    reference.viaInterpreter !== true &&
    !context.isExecutable(resolved.relative)
  ) {
    return `is not executable (${resolved.relative})`;
  }

  return undefined;
};

const defaultIsUnanchored = (reference: ScriptReference): boolean =>
  reference.kind === 'relative';

const eventCheck = (context: RuleContext): readonly RawFinding[] =>
  context.settingsFiles.flatMap((file) =>
    Object.keys(eventsOf(file))
      .filter((event) => !KNOWN_HOOK_EVENTS.has(event))
      .map((event) => ({
        file: file.path,
        line: lineOfJsonKey(file.text, event),
        message: `${event} is not a documented hook event, so its hooks may never run.`,
        remediation:
          'Rename the key to a documented event such as PreToolUse, or remove it.',
      }))
  );

/** Builds the hook rules; the optional predicates let a test prove each rule can fail. */
export const createHookRules = (
  options: HookRuleOptions = {}
): readonly RuleDefinition[] => {
  const findScriptProblem =
    options.findScriptProblem ?? defaultFindScriptProblem;
  const isUnanchored = options.isUnanchored ?? defaultIsUnanchored;

  const pathCheck = (context: RuleContext): readonly RawFinding[] =>
    context.settingsFiles.flatMap((file) =>
      hookEntriesOf(file).flatMap((entry) => {
        const problem = findScriptProblem(
          context,
          readScriptReference(entry.command),
          file.path
        );

        if (problem === undefined) return [];

        return [
          {
            file: file.path,
            line: entry.line,
            message: `The ${entry.event} hook script ${problem}. A hook command that cannot run exits 126 or 127, which neither blocks nor warns, so the guard fails open.`,
            remediation:
              'Fix the script path, create the script, or run chmod +x on it.',
          },
        ];
      })
    );

  const rootedCheck = (context: RuleContext): readonly RawFinding[] =>
    context.settingsFiles.flatMap((file) =>
      hookEntriesOf(file).flatMap((entry) => {
        if (!isUnanchored(readScriptReference(entry.command))) return [];

        return [
          {
            file: file.path,
            line: entry.line,
            message: `The ${entry.event} hook names its script by a repo-relative path, which resolves against the shell's current directory and goes missing after one cd.`,
            remediation:
              'Prefix the script path with the project root, for example "$(git rev-parse --show-toplevel)/".',
          },
        ];
      })
    );

  return [
    {
      appliesTo: ['settings', 'settings-local'],
      category: 'hooks',
      check: eventCheck,
      detection:
        'A key under hooks is not an event Claude Code documents (warning, so a newer event never blocks).',
      ruleId: 'hooks.event-name',
      severity: 'warning',
    },
    {
      appliesTo: ['settings', 'settings-local'],
      category: 'hooks',
      check: pathCheck,
      detection:
        'A hook command names a script under a recognized project-root prefix that does not exist or is not executable; the command is read statically and never run.',
      ruleId: 'hooks.path-exists-executable',
      severity: 'error',
    },
    {
      appliesTo: ['settings', 'settings-local'],
      category: 'hooks',
      check: rootedCheck,
      detection:
        'A hook command names its script by a repo-relative path instead of an absolute, $-expanded or substituted root.',
      ruleId: 'hooks.rooted-command',
      severity: 'error',
    },
  ];
};

export const HOOKS_RULES: readonly RuleDefinition[] = createHookRules();
