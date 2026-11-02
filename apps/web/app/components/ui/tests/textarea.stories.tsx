import {useTranslation} from 'react-i18next';
import preview from '#.storybook/preview';
import {Textarea} from '~/components/ui/textarea';

const meta = preview.meta({
  component: Textarea,
  parameters: {
    wrap: 'max-w-sm p-4',
  },
  title: 'Components/Ui/Textarea',
});

export const Default = meta.story({
  render: () => {
    const {t} = useTranslation();

    return <Textarea aria-label={t('description')} />;
  },
});

export const Invalid = meta.story({
  render: () => {
    const {t} = useTranslation();

    return <Textarea aria-invalid={true} aria-label={t('description')} />;
  },
});

export const Disabled = meta.story({
  render: () => {
    const {t} = useTranslation();

    return <Textarea aria-label={t('description')} disabled={true} />;
  },
});
