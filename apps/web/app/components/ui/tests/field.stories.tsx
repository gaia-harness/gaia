import {useTranslation} from 'react-i18next';
import preview from '#.storybook/preview';
import {Checkbox} from '~/components/ui/checkbox';
import {
  Field,
  FieldDescription,
  FieldError,
  FieldGroup,
  FieldLabel,
  FieldLegend,
  FieldSet,
} from '~/components/ui/field';
import {Input} from '~/components/ui/input';

const meta = preview.meta({
  component: Field,
  parameters: {
    wrap: 'max-w-md p-4',
  },
  title: 'Components/Ui/Field',
});

export const Default = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <FieldSet>
        <FieldLegend>{t('form.allFieldsAreRequired')}</FieldLegend>
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="fieldStoryName">{t('name')}</FieldLabel>
            <Input id="fieldStoryName" />
          </Field>
          <Field>
            <FieldLabel htmlFor="fieldStoryEmail">{t('email')}</FieldLabel>
            <Input
              aria-describedby="fieldStoryEmailDescription"
              id="fieldStoryEmail"
              placeholder={t('emailPlaceholder')}
            />
            <FieldDescription id="fieldStoryEmailDescription">
              {t('form.required')}
            </FieldDescription>
          </Field>
        </FieldGroup>
      </FieldSet>
    );
  },
});

export const Horizontal = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <Field orientation="horizontal">
        <Checkbox id="fieldStoryHorizontal" />
        <FieldLabel htmlFor="fieldStoryHorizontal">{t('form.ok')}</FieldLabel>
      </Field>
    );
  },
});

export const Responsive = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <Field orientation="responsive">
        <FieldLabel htmlFor="fieldStoryResponsive">{t('name')}</FieldLabel>
        <Input id="fieldStoryResponsive" />
      </Field>
    );
  },
});

export const WithError = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <Field data-invalid={true}>
        <FieldLabel htmlFor="fieldStoryError">{t('email')}</FieldLabel>
        <Input
          aria-describedby="fieldStoryErrorMessage"
          aria-invalid={true}
          id="fieldStoryError"
        />
        <FieldError id="fieldStoryErrorMessage">
          {t('form.required')}
        </FieldError>
      </Field>
    );
  },
});

export const LegendLabelVariant = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <FieldSet>
        <FieldLegend variant="label">{t('name')}</FieldLegend>
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="fieldStoryLegendLabel">
              {t('email')}
            </FieldLabel>
            <Input id="fieldStoryLegendLabel" />
          </Field>
        </FieldGroup>
      </FieldSet>
    );
  },
});

export const Disabled = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <Field data-disabled={true}>
        <FieldLabel htmlFor="fieldStoryDisabled">{t('email')}</FieldLabel>
        <Input disabled={true} id="fieldStoryDisabled" />
      </Field>
    );
  },
});
