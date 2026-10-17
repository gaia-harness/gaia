/** Every theme a user can pick; `system` follows the OS color scheme. */
export const THEME_PREFERENCES = ['dark', 'light', 'system'] as const;

export type ThemePreference = (typeof THEME_PREFERENCES)[number];

// Widened to unknown so membership can be asked of any value: the tuple's own
// includes() only accepts its members, which defeats a type guard.
const THEME_PREFERENCE_SET: ReadonlySet<unknown> = new Set(THEME_PREFERENCES);

/** Narrows an untyped value, such as a form field, to a ThemePreference. */
export const isThemePreference = (value: unknown): value is ThemePreference =>
  THEME_PREFERENCE_SET.has(value);
