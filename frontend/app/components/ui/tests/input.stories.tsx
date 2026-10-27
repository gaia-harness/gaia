import {useTranslation} from 'react-i18next';
import preview from '#.storybook/preview';
import {Input} from '~/components/ui/input';

const meta = preview.meta({
  component: Input,
  parameters: {
    wrap: 'max-w-sm p-4',
  },
  title: 'Components/Ui/Input',
});

export const Default = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <Input aria-label={t('email')} placeholder={t('emailPlaceholder')} />
    );
  },
});

export const Invalid = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <Input
        aria-invalid={true}
        aria-label={t('email')}
        placeholder={t('emailPlaceholder')}
      />
    );
  },
});

export const Disabled = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <Input
        aria-label={t('email')}
        disabled={true}
        placeholder={t('emailPlaceholder')}
      />
    );
  },
});
