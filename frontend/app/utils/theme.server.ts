import {parseCookie, stringifySetCookie} from 'cookie';
import {env} from '~/env.server';
import {isThemePreference} from '~/utils/theme';
import type {ThemePreference} from '~/utils/theme';

const COOKIE_NAME = '__theme';

export type Theme = Exclude<ThemePreference, 'system'>;

export const getTheme = (request: Request): Theme | undefined => {
  const cookieHeader = request.headers.get('Cookie');
  if (!cookieHeader) return undefined;
  const parsed = parseCookie(cookieHeader)[COOKIE_NAME];
  if (isThemePreference(parsed) && parsed !== 'system') return parsed;

  return undefined;
};

export const setTheme = (theme: ThemePreference): string => {
  if (theme === 'system') {
    return stringifySetCookie({
      httpOnly: true,
      maxAge: -1,
      name: COOKIE_NAME,
      path: '/',
      sameSite: 'lax',
      secure: env.NODE_ENV === 'production',
      value: '',
    });
  }

  return stringifySetCookie({
    httpOnly: true,
    maxAge: 31_536_000,
    name: COOKIE_NAME,
    path: '/',
    sameSite: 'lax',
    secure: env.NODE_ENV === 'production',
    value: theme,
  });
};
