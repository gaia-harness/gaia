import {useTranslation} from 'react-i18next';
import preview from '#.storybook/preview';
import {RadioGroup, RadioGroupItem} from '~/components/ui/radio-group';

const meta = preview.meta({
  component: RadioGroup,
  parameters: {
    wrap: 'w-fit p-4',
  },
  title: 'Components/Ui/RadioGroup',
});

export const Default = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <RadioGroup aria-label={t('theme.useSystemTheme')} defaultValue="one">
        <RadioGroupItem aria-label={t('theme.light')} value="one" />
        <RadioGroupItem aria-label={t('theme.dark')} value="two" />
      </RadioGroup>
    );
  },
});

export const Invalid = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <RadioGroup aria-label={t('theme.useSystemTheme')} defaultValue="one">
        <RadioGroupItem
          aria-invalid={true}
          aria-label={t('theme.light')}
          value="one"
        />
        <RadioGroupItem
          aria-invalid={true}
          aria-label={t('theme.dark')}
          value="two"
        />
      </RadioGroup>
    );
  },
});

export const Disabled = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <RadioGroup
        aria-label={t('theme.useSystemTheme')}
        defaultValue="one"
        disabled={true}
      >
        <RadioGroupItem aria-label={t('theme.light')} value="one" />
        <RadioGroupItem aria-label={t('theme.dark')} value="two" />
      </RadioGroup>
    );
  },
});
