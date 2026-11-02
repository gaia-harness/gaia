import {initReactI18next} from 'react-i18next';
import i18next from 'i18next';
import i18n, {DEFAULT_LOCALE} from '~/i18n';

await i18next.use(initReactI18next).init({
  ...i18n,
  lng: DEFAULT_LOCALE,
  ns: ['common'],
});

export default i18next;
