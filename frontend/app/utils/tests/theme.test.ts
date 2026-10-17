import {describe, expect, test} from 'vitest';
import {isThemePreference, THEME_PREFERENCES} from '~/utils/theme';

describe('isThemePreference', () => {
  test.each(THEME_PREFERENCES)('accepts %s', (preference) => {
    expect(isThemePreference(preference)).toBe(true);
  });

  test.each([undefined, null, '', 'Dark', 'sepia', 1])(
    'rejects %s',
    (value) => {
      expect(isThemePreference(value)).toBe(false);
    }
  );
});
