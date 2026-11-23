import {describe, expect, test} from 'vitest';
import {mergeSandboxSettings} from '../apply.js';
import {seedSandboxConfig} from '../seed.js';

const defaultNetwork = {allowedDomains: ['registry.npmjs.org']};

describe('mergeSandboxSettings', () => {
  test.each([
    {
      dockerPresent: true,
      existing: {},
      expectedRest: {},
      expectedSandbox: {
        enabled: true,
        excludedCommands: ['docker *'],
        network: defaultNetwork,
      },
      name: 'merges the seed fragment into an empty settings object',
      registry: undefined,
    },
    {
      dockerPresent: false,
      existing: {someOtherKey: {nested: true}},
      expectedRest: {someOtherKey: {nested: true}},
      expectedSandbox: {enabled: true, network: defaultNetwork},
      name: 'preserves pre-existing unrelated top-level keys',
      registry: undefined,
    },
    {
      dockerPresent: false,
      existing: {sandbox: {unrelatedSandboxKey: 'keep-me'}},
      expectedRest: {},
      expectedSandbox: {
        enabled: true,
        network: defaultNetwork,
        unrelatedSandboxKey: 'keep-me',
      },
      name: 'merges nested rather than clobbering a pre-existing sandbox block wholesale',
      registry: undefined,
    },
    {
      dockerPresent: false,
      existing: {sandbox: {network: {allowedDomains: ['old.example.com']}}},
      expectedRest: {},
      expectedSandbox: {
        enabled: true,
        network: {allowedDomains: ['npm.example.com']},
      },
      name: 'array values (allowedDomains) are replaced wholesale, not merged element-wise',
      registry: 'https://npm.example.com/',
    },
  ])(
    '$name',
    ({dockerPresent, existing, expectedRest, expectedSandbox, registry}) => {
      const fragment = seedSandboxConfig({dockerPresent, registry});

      const merged = mergeSandboxSettings(existing, fragment);

      expect(merged).toEqual({...expectedRest, sandbox: expectedSandbox});
    }
  );
});
