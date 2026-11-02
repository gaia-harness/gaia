import {useTranslation} from 'react-i18next';
import preview from '#.storybook/preview';
import {Input} from '~/components/ui/input';
import {Label} from '~/components/ui/label';

const meta = preview.meta({
  component: Label,
  parameters: {
    wrap: 'max-w-sm p-4',
  },
  title: 'Components/Ui/Label',
});

export const Default = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <div className="flex flex-col gap-2">
        <Label htmlFor="labelStoryInput">{t('email')}</Label>
        <Input id="labelStoryInput" type="email" />
      </div>
    );
  },
});

export const Disabled = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <div className="group flex flex-col gap-2" data-disabled={true}>
        <Label htmlFor="labelStoryDisabledInput">{t('email')}</Label>
        <Input disabled={true} id="labelStoryDisabledInput" type="email" />
      </div>
    );
  },
});
