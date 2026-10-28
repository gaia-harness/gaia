import {useTranslation} from 'react-i18next';
import preview from '#.storybook/preview';
import {
  NativeSelect,
  NativeSelectOptGroup,
  NativeSelectOption,
} from '~/components/ui/native-select';

const meta = preview.meta({
  component: NativeSelect,
  parameters: {
    wrap: 'p-4',
  },
  title: 'Components/Ui/NativeSelect',
});

const Options = () => {
  const {t} = useTranslation();

  return (
    <>
      <NativeSelectOption value="">
        {t('theme.useSystemTheme')}
      </NativeSelectOption>
      <NativeSelectOptGroup label={t('form.optional')}>
        <NativeSelectOption value="light">
          {t('theme.light')}
        </NativeSelectOption>
        <NativeSelectOption value="dark">{t('theme.dark')}</NativeSelectOption>
      </NativeSelectOptGroup>
    </>
  );
};

export const Default = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <div className="flex flex-col items-start gap-4">
        <NativeSelect aria-label={t('theme.useSystemTheme')}>
          <Options />
        </NativeSelect>
        <NativeSelect aria-label={t('theme.useSystemTheme')} size="sm">
          <Options />
        </NativeSelect>
      </div>
    );
  },
});

export const Invalid = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <NativeSelect aria-invalid={true} aria-label={t('theme.useSystemTheme')}>
        <Options />
      </NativeSelect>
    );
  },
});

export const Disabled = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <NativeSelect aria-label={t('theme.useSystemTheme')} disabled={true}>
        <Options />
      </NativeSelect>
    );
  },
});
