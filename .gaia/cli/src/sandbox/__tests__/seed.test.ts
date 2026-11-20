import {describe, expect, test} from 'vitest';
import {extractRegistryHost, seedSandboxConfig} from '../seed.js';

describe('extractRegistryHost', () => {
  test.each([
    {
      expected: 'registry.npmjs.org',
      input: undefined,
      name: 'undefined falls back to the default registry host',
    },
    {
      expected: 'registry.npmjs.org',
      input: '',
      name: 'empty string falls back to the default registry host',
    },
    {
      expected: 'registry.npmjs.org',
      input: 'not a url',
      name: 'unparseable value falls back to the default registry host',
    },
    {
      expected: 'registry.npmjs.org',
      input: 'https://registry.npmjs.org/',
      name: 'the default registry URL round-trips to its own host',
    },
    {
      expected: 'npm.example.com',
      input: 'https://user:token@npm.example.com/',
      name: 'a credential-bearing URL yields host only, never the credentials',
    },
  ])('$name', ({expected, input}) => {
    const host = extractRegistryHost(input);

    expect(host).toBe(expected);
    expect(host).not.toContain('user');
    expect(host).not.toContain('token');
  });
});

describe('seedSandboxConfig', () => {
  const defaultNetwork = {allowedDomains: ['registry.npmjs.org']};

  test.each([
    {
      dockerPresent: false,
      expectedSandbox: {enabled: true, network: defaultNetwork},
      hasExcludedCommands: false,
      name: 'default registry: allowedDomains is exactly [registry.npmjs.org]',
      registry: undefined,
    },
    {
      dockerPresent: true,
      expectedSandbox: {
        enabled: true,
        excludedCommands: ['docker *'],
        network: defaultNetwork,
      },
      hasExcludedCommands: true,
      name: 'dockerPresent true: excludedCommands contains "docker *"',
      registry: undefined,
    },
    {
      dockerPresent: false,
      expectedSandbox: {enabled: true, network: defaultNetwork},
      hasExcludedCommands: false,
      name: 'dockerPresent false: the excludedCommands key is absent',
      registry: undefined,
    },
    {
      dockerPresent: false,
      expectedSandbox: {enabled: true, network: defaultNetwork},
      hasExcludedCommands: false,
      name: 'sandbox.enabled is always true',
      registry: undefined,
    },
    {
      dockerPresent: false,
      expectedSandbox: {
        enabled: true,
        network: {allowedDomains: ['npm.example.com']},
      },
      hasExcludedCommands: false,
      name: 'a custom registry resolves to its own host in allowedDomains',
      registry: 'https://user:token@npm.example.com/',
    },
  ])(
    '$name',
    ({dockerPresent, expectedSandbox, hasExcludedCommands, registry}) => {
      const fragment = seedSandboxConfig({dockerPresent, registry});

      expect(fragment.sandbox).toEqual(expectedSandbox);
      expect('excludedCommands' in fragment.sandbox).toBe(hasExcludedCommands);
    }
  );
});
