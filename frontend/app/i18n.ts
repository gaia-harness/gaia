import type {FormatFunction} from 'i18next';
import resources, {LANGUAGES} from '~/languages';

export const DEFAULT_LOCALE = 'en';

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- i18next types the formatted value as `any`
const formatInterpolatedValue: FormatFunction = (value: any, format?: string) =>
  // eslint-disable-next-line @typescript-eslint/no-unsafe-return -- a non-number value passes through untouched
  format === 'number' ? Number(value).toLocaleString() : value;

const i18n = {
  defaultNS: 'common',
  fallbackLng: DEFAULT_LOCALE,
  fallbackNS: ['common'],
  interpolation: {
    escapeValue: false,
    format: formatInterpolatedValue,
  },
  lowerCaseLng: true,
  react: {useSuspense: false},
  resources,
  returnNull: false,
  showSupportNotice: false,
  supportedLngs: LANGUAGES,
};

export default i18n;
