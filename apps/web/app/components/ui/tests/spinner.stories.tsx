import {useTranslation} from 'react-i18next';
import preview from '#.storybook/preview';
import {Spinner} from '~/components/ui/spinner';

const meta = preview.meta({
  component: Spinner,
  parameters: {
    chromatic: {disableSnapshot: true},
    wrap: 'w-fit p-4',
  },
  title: 'Components/Ui/Spinner',
});

export const Default = meta.story({
  render: () => {
    const {t} = useTranslation();

    return <Spinner aria-label={t('loading')} />;
  },
});
