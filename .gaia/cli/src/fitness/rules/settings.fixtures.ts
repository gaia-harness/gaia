import {randomBytes} from 'node:crypto';
import type {FixtureMap, FixtureProject} from '../types.js';

/** A credential-shaped value built at call time, never a committed literal. */
export const buildCredentialValue = (): string =>
  `sk-ant-${randomBytes(16).toString('hex')}`;

const withPermissions = (
  permissions: Record<string, unknown>
): FixtureProject => ({
  files: {},
  git: true,
  settingsJson: {permissions},
});

/** A local settings file that no ignore rule covers, whatever the machine's global git ignore says. */
export const RED_LOCAL_SETTINGS: FixtureProject = {
  files: {
    '.claude/settings.local.json': '{}\n',
    '.gitignore': '!.claude/settings.local.json\n',
  },
  git: true,
};

export const SETTINGS_FIXTURES: FixtureMap = {
  'settings.env-secrets': {
    green: () => ({
      files: {},
      git: true,
      settingsJson: {env: {EXAMPLE_MODE: 'strict', EXAMPLE_TOKEN: ''}},
    }),
    red: () => ({
      files: {},
      git: true,
      settingsJson: {env: {EXAMPLE_SETTING: buildCredentialValue()}},
    }),
  },
  'settings.local-gitignored': {
    green: () => ({
      files: {
        '.claude/settings.local.json': '{}\n',
        '.gitignore': '.claude/settings.local.json\n',
      },
      git: true,
    }),
    // The negation keeps the fixture red on a machine whose global git ignore
    // already covers the file.
    red: () => RED_LOCAL_SETTINGS,
  },
  'settings.redundant-permissions': {
    green: () => withPermissions({allow: ['Bash(ls:*)', 'Read']}),
    red: () => withPermissions({allow: ['Bash', 'Bash(ls)']}),
  },
  'settings.valid-json': {
    green: () => ({files: {'.claude/settings.json': '{}\n'}, git: true}),
    red: () => ({files: {'.claude/settings.json': '{ "env": '}, git: true}),
  },
};
