/* eslint-disable no-template-curly-in-string -- these literals are shell text, not templates */
import type {FixtureMap, FixtureProject} from '../types.js';

export const SANCTIONED_ROOT =
  '$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-.}")';

/** A project whose settings register `command` under `event`; `files` adds repo files. */
export const hookProject = (
  command: string,
  options: {
    event?: string;
    files?: Record<string, string>;
    path?: string;
  } = {}
): FixtureProject => {
  const settings = {
    hooks: {
      [options.event ?? 'PreToolUse']: [
        {hooks: [{command, type: 'command'}], matcher: 'Bash'},
      ],
    },
  };

  return {
    files: {
      ...options.files,
      ...(options.path === undefined ?
        {}
      : {[options.path]: `${JSON.stringify(settings, null, 2)}\n`}),
    },
    git: true,
    ...(options.path === undefined ? {settingsJson: settings} : {}),
  };
};

// The scratch writer cannot set a file mode, so no fixture can hold an
// executable script; the green fixtures name a command the rule does not stat.
const UNSTATTED_COMMAND = 'jq -r .tool_input.command';

export const HOOKS_FIXTURES: FixtureMap = {
  'hooks.event-name': {
    green: () => hookProject(UNSTATTED_COMMAND, {event: 'PreToolUse'}),
    red: () => hookProject(UNSTATTED_COMMAND, {event: 'PreToolRun'}),
  },
  'hooks.path-exists-executable': {
    green: () => hookProject(UNSTATTED_COMMAND),
    red: () => hookProject('"$CLAUDE_PROJECT_DIR"/.claude/hooks/missing.sh'),
  },
  'hooks.rooted-command': {
    green: () => hookProject('$HOME/hooks/example.sh'),
    red: () =>
      hookProject('.claude/hooks/example.sh', {
        files: {'.claude/hooks/example.sh': '#!/usr/bin/env bash\n'},
      }),
  },
};
