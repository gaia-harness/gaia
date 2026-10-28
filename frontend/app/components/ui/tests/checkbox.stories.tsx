import {useTranslation} from 'react-i18next';
import {expect, userEvent} from 'storybook/test';
import preview from '#.storybook/preview';
import {Checkbox} from '~/components/ui/checkbox';
import {Field, FieldLabel} from '~/components/ui/field';
import {Label} from '~/components/ui/label';

const meta = preview.meta({
  component: Checkbox,
  parameters: {
    wrap: 'w-fit p-4',
  },
  title: 'Components/Ui/Checkbox',
});

export const Default = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <div className="flex gap-4">
        <Checkbox aria-label={t('form.ok')} />
        <Checkbox aria-label={t('form.ok')} defaultChecked={true} />
      </div>
    );
  },
});

export const Invalid = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <div className="flex gap-4">
        <Checkbox aria-invalid={true} aria-label={t('form.ok')} />
        <Checkbox
          aria-invalid={true}
          aria-label={t('form.ok')}
          defaultChecked={true}
        />
      </div>
    );
  },
});

export const Disabled = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <div className="flex gap-4">
        <Checkbox aria-label={t('form.ok')} disabled={true} />
        <Checkbox
          aria-label={t('form.ok')}
          defaultChecked={true}
          disabled={true}
        />
      </div>
    );
  },
});

export const WithLabel = meta.story({
  render: () => (
    <div className="flex gap-2">
      <Checkbox id="acceptPlain" />
      <Label htmlFor="acceptPlain">Accept</Label>
    </div>
  ),
});

export const WithFieldLabel = meta.story({
  render: () => (
    <Field orientation="horizontal">
      <Checkbox id="accept" />
      <FieldLabel htmlFor="accept">Accept</FieldLabel>
    </Field>
  ),
});

export const WithClassName = meta.story({
  render: () => <Checkbox aria-label="Accept" className="mt-2" />,
});

WithLabel.test('takes its accessible name from the label', async ({canvas}) => {
  await expect(
    canvas.getByRole('checkbox', {name: 'Accept'})
  ).toHaveAccessibleName('Accept');
});

WithLabel.test(
  'toggles with the space key and keeps focus',
  async ({canvas}) => {
    const checkbox = canvas.getByRole('checkbox', {name: 'Accept'});

    await userEvent.tab();
    await expect(checkbox).toHaveFocus();
    await expect(checkbox).not.toBeChecked();

    await userEvent.keyboard(' ');

    await expect(checkbox).toBeChecked();
    await expect(checkbox).toHaveFocus();
  }
);

WithFieldLabel.test(
  'takes its accessible name from the field label',
  async ({canvas}) => {
    await expect(
      canvas.getByRole('checkbox', {name: 'Accept'})
    ).toHaveAccessibleName('Accept');
  }
);

WithClassName.test('applies the passed class name', async ({canvas}) => {
  await expect(canvas.getByRole('checkbox', {name: 'Accept'})).toHaveClass(
    'mt-2'
  );
});
