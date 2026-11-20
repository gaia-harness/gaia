import {describe, expect, test} from 'vitest';
import {classifyCapability} from '../capability.js';

const aptInstall = 'sudo apt-get install bubblewrap socat';

describe('classifyCapability', () => {
  test.each([
    {
      capability: 'ready',
      input: {platform: 'darwin'},
      installCommand: undefined,
      name: 'darwin is always ready',
      reasonIncludes: [],
    },
    {
      capability: 'ready',
      input: {hasBwrap: true, hasSocat: true, platform: 'linux'},
      installCommand: undefined,
      name: 'linux with bwrap and socat is ready',
      reasonIncludes: [],
    },
    {
      capability: 'needs-deps',
      input: {hasBwrap: false, hasSocat: true, platform: 'linux'},
      installCommand: aptInstall,
      name: 'linux missing bwrap is needs-deps with the pinned apt install command and a Fedora mention',
      reasonIncludes: ['sudo dnf install bubblewrap socat'],
    },
    {
      capability: 'needs-deps',
      input: {hasBwrap: true, hasSocat: false, platform: 'linux'},
      installCommand: aptInstall,
      name: 'linux missing socat is needs-deps with the pinned apt install command',
      reasonIncludes: [],
    },
    {
      capability: 'needs-deps',
      input: {platform: 'linux'},
      installCommand: aptInstall,
      name: 'linux missing both deps is needs-deps',
      reasonIncludes: [],
    },
    {
      capability: 'needs-deps',
      input: {
        hasBwrap: false,
        hasSocat: false,
        platform: 'linux',
        wsl: 'wsl2',
      },
      installCommand: aptInstall,
      name: 'wsl2 missing deps is needs-deps (linux path applies under WSL2)',
      reasonIncludes: [],
    },
    {
      capability: 'ready',
      input: {hasBwrap: true, hasSocat: true, platform: 'linux', wsl: 'wsl2'},
      installCommand: undefined,
      name: 'wsl2 with deps present is ready',
      reasonIncludes: [],
    },
    {
      capability: 'unsupported',
      input: {platform: 'win32'},
      installCommand: undefined,
      name: 'win32 is unsupported and names WSL2 as the path',
      reasonIncludes: ['WSL2'],
    },
    {
      capability: 'unsupported',
      input: {platform: 'linux', wsl: 'wsl1'},
      installCommand: undefined,
      name: 'wsl1 is unsupported and names WSL2 as the path',
      reasonIncludes: ['WSL2'],
    },
  ] as const)(
    '$name',
    ({capability, input, installCommand, reasonIncludes}) => {
      const result = classifyCapability(input);

      expect(result.capability).toBe(capability);
      expect(result.installCommand).toBe(installCommand);

      for (const fragment of reasonIncludes) {
        expect(result.reason).toContain(fragment);
      }
    }
  );
});
