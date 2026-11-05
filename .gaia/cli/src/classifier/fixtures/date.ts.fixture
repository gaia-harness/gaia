import type {Locale} from 'date-fns';
import {format} from 'date-fns';
import {ja} from 'date-fns/locale';

// date-fns falls back to en-US when no `locale` option is supplied; `en` and
// any language without a registered date-fns locale share that default.
const DATE_FNS_LOCALES: Partial<Record<string, Locale>> = {
  ja,
};

const getLocaleOptions = (language: string): undefined | {locale: Locale} => {
  const locale = DATE_FNS_LOCALES[language];

  return locale ? {locale} : undefined;
};

// Jan 15, Nov 3, etc.
export const formatAbbreviatedMonthDay = (
  date: Date,
  language: string
): string =>
  format(
    date,
    `MMM d${language === 'en' ? '' : 'o'}`,
    getLocaleOptions(language)
  );

// Jan 15th, Nov 3rd, etc.
export const formatAbbreviatedMonthOrdinalDay = (
  date: Date,
  language: string
): string => format(date, 'MMM do', getLocaleOptions(language));

export const formatISO8601Date = (date: Date): string =>
  format(date, 'yyyy-MM-dd');

export const formatFullDate = (date: Date, language: string): string =>
  format(date, 'PPPP', getLocaleOptions(language));

// locale-insensitive by design: MM/yy is a universal card-expiry format
export const formatMonthYear = (date = new Date()): string =>
  format(date, 'MM/yy');

export const formatTime = (date: Date, language: string): string =>
  format(date, 'p', getLocaleOptions(language));

export const formatTime24 = (date: Date): string => format(date, 'HH:mm');
