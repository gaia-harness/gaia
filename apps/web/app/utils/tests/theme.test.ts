import {describe, expect, test} from 'vitest';
import {isThemePreference} from '~/utils/theme';

describe('isThemePreference', () => {
  test.each([undefined, null, '', 'Dark', 'sepia', 1])(
    'rejects %s',
    (value) => {
      expect(isThemePreference(value)).toBe(false);
    }
  );
});
