import {afterEach, describe, expect, test, vi} from 'vitest';
import {run} from './index.js';

describe('gaia migrate-csf4 help', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  test.each(['--help', '-h', 'help'])(
    '%s prints the usage and exits 0 without migrating',
    (token) => {
      const stdout = vi
        .spyOn(process.stdout, 'write')
        .mockImplementation(() => true);
      const stderr = vi
        .spyOn(process.stderr, 'write')
        .mockImplementation(() => true);

      expect(run([token])).toBe(0);
      expect(stdout.mock.calls.join('')).toContain(
        'Usage: gaia migrate-csf4 [--update-merge] [--json]'
      );
      expect(stderr).not.toHaveBeenCalled();
    }
  );
});
