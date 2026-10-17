import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from '../../exit.js';
import {run} from '../index.js';

const REPOSITORY_POLICY_VERBS = [
  'check-admin',
  'configure-dependabot-alerts',
  'detect-remote',
  'drift',
  'record',
  'enable-delete-branch',
  'warn-existing-tools',
  'write-isolation-policy',
  'write-sandbox-recommendation',
] as const;

let outputs: string[];
let stdoutSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  outputs = [];
  stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
});

afterEach(() => {
  stdoutSpy.mockRestore();
});

describe('gaia setup router', () => {
  test.each(REPOSITORY_POLICY_VERBS)(
    'dispatches %s to its own handler',
    async (verb) => {
      await expect(run([verb, '--help'])).resolves.toBe(EXIT_CODES.OK);
      expect(outputs.join('')).toContain(`Usage: gaia setup ${verb}`);
    }
  );

  test('dispatches bootstrap-env to its own handler', async () => {
    await expect(run(['bootstrap-env', '--help'])).resolves.toBe(EXIT_CODES.OK);
    expect(outputs.join('')).toContain('Usage: gaia setup bootstrap-env');
  });

  test('the help lists every verb the router serves', async () => {
    await expect(run(['--help'])).resolves.toBe(EXIT_CODES.OK);

    const help = outputs.join('');

    for (const verb of [
      'status',
      'mark-step',
      'finalize',
      'bootstrap-env',
      ...REPOSITORY_POLICY_VERBS,
    ]) {
      expect(help).toContain(verb);
    }
  });
});
