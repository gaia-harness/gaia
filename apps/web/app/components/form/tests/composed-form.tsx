import {useTranslation} from 'react-i18next';
import {Form, useActionData, useNavigation} from 'react-router';
import type {SubmissionResult} from '@conform-to/react';
import {
  getCollectionProps,
  getFormProps,
  getInputProps,
  getSelectProps,
  getTextareaProps,
  useForm,
} from '@conform-to/react';
import {getZodConstraint, parseWithZod} from '@conform-to/zod/v4';
import {z} from 'zod';
import ConformField from '~/components/form/conform-field';
import ConformFieldError from '~/components/form/conform-field-error';
import {Button} from '~/components/ui/button';
import {Checkbox} from '~/components/ui/checkbox';
import {Field, FieldLabel, FieldLegend, FieldSet} from '~/components/ui/field';
import {Input} from '~/components/ui/input';
import {NativeSelect, NativeSelectOption} from '~/components/ui/native-select';
import {RadioGroup, RadioGroupItem} from '~/components/ui/radio-group';
import {Spinner} from '~/components/ui/spinner';
import {Textarea} from '~/components/ui/textarea';
import {omitType} from '~/utils/object';

// Sorted `as const` lists feed the schema; the display-order lists drive rendering.
const COLORS = ['blue', 'green', 'red'] as const;
const COUNTRIES = ['fr', 'jp', 'us'] as const;
const SIZES = ['lg', 'md', 'sm'] as const;

const COLORS_DISPLAY_ORDER: (typeof COLORS)[number][] = [
  'red',
  'green',
  'blue',
];
const SIZES_DISPLAY_ORDER: (typeof SIZES)[number][] = ['sm', 'md', 'lg'];

const REQUIRED_MESSAGE = 'required';

// Strings used only by this fixture, kept here so they do not ship in the
// adopter `common` namespace.
const FIXTURE_TEXT = {
  bio: 'Bio',
  colorOptions: {blue: 'Blue', green: 'Green', red: 'Red'},
  colors: 'Favorite colors',
  country: 'Country',
  countryOptions: {
    fr: 'France',
    jp: 'Japan',
    none: 'Select a country',
    us: 'United States',
  },
  passwordDescription: 'Use at least 8 characters',
  passwordError: 'Password must be at least 8 characters',
  size: 'Size',
  sizeOptions: {lg: 'Large', md: 'Medium', sm: 'Small'},
  terms: 'I accept the terms',
} as const;

export const composedFormSchema = z.object({
  bio: z.string().optional(),
  colors: z
    .array(z.literal(COLORS), {error: REQUIRED_MESSAGE})
    .min(1, REQUIRED_MESSAGE),
  country: z.literal(COUNTRIES).optional(),
  email: z.email({error: 'email'}).optional(),
  name: z.string({error: REQUIRED_MESSAGE}).min(1, REQUIRED_MESSAGE),
  password: z.string().min(8, FIXTURE_TEXT.passwordError).optional(),
  size: z.literal(SIZES, {error: REQUIRED_MESSAGE}),
  terms: z.boolean().optional(),
});

type ComposedFormProps = {
  disabled?: boolean;
};

export const ComposedForm = ({disabled = false}: ComposedFormProps) => {
  const {t} = useTranslation('common');
  const actionData = useActionData<{result: SubmissionResult}>();
  const navigation = useNavigation();
  const isSubmitting = navigation.state === 'submitting';

  const [form, fields] = useForm({
    constraint: getZodConstraint(composedFormSchema),
    lastResult: actionData?.result,
    onValidate: ({formData}) =>
      parseWithZod(formData, {schema: composedFormSchema}),
    shouldRevalidate: 'onInput',
    shouldValidate: 'onBlur',
  });

  const colorLabels = FIXTURE_TEXT.colorOptions satisfies Record<
    (typeof COLORS)[number],
    string
  >;
  const countryLabels = FIXTURE_TEXT.countryOptions satisfies Record<
    'none' | (typeof COUNTRIES)[number],
    string
  >;
  const sizeLabels = FIXTURE_TEXT.sizeOptions satisfies Record<
    (typeof SIZES)[number],
    string
  >;

  return (
    <Form
      className="flex max-w-md flex-col gap-6 p-4"
      method="post"
      {...getFormProps(form)}
    >
      <ConformField field={fields.name} label={t('name')}>
        {(controlOptions) => (
          <Input
            {...getInputProps(fields.name, {...controlOptions, type: 'text'})}
            disabled={disabled}
          />
        )}
      </ConformField>

      <ConformField field={fields.email} label={t('email')}>
        {(controlOptions) => (
          <Input
            {...getInputProps(fields.email, {...controlOptions, type: 'email'})}
            disabled={disabled}
            placeholder={t('emailPlaceholder')}
          />
        )}
      </ConformField>

      <ConformField
        description={FIXTURE_TEXT.passwordDescription}
        field={fields.password}
        label={t('password')}
      >
        {(controlOptions) => (
          <Input
            {...getInputProps(fields.password, {
              ...controlOptions,
              type: 'password',
            })}
            disabled={disabled}
          />
        )}
      </ConformField>

      <ConformField field={fields.bio} label={FIXTURE_TEXT.bio}>
        {(controlOptions) => (
          <Textarea
            {...getTextareaProps(fields.bio, controlOptions)}
            disabled={disabled}
          />
        )}
      </ConformField>

      <ConformField field={fields.country} label={FIXTURE_TEXT.country}>
        {(controlOptions) => (
          <NativeSelect
            {...getSelectProps(fields.country, controlOptions)}
            disabled={disabled}
          >
            <NativeSelectOption value="">
              {FIXTURE_TEXT.countryOptions.none}
            </NativeSelectOption>
            {COUNTRIES.map((country) => (
              <NativeSelectOption key={country} value={country}>
                {countryLabels[country]}
              </NativeSelectOption>
            ))}
          </NativeSelect>
        )}
      </ConformField>

      <ConformField
        field={fields.terms}
        label={FIXTURE_TEXT.terms}
        orientation="horizontal"
      >
        {(controlOptions) => (
          <Checkbox
            {...omitType(
              getInputProps(fields.terms, {
                ...controlOptions,
                type: 'checkbox',
              })
            )}
            disabled={disabled}
          />
        )}
      </ConformField>

      <FieldSet disabled={disabled}>
        <FieldLegend variant="label">{FIXTURE_TEXT.colors}</FieldLegend>
        {getCollectionProps(fields.colors, {
          options: COLORS_DISPLAY_ORDER,
          type: 'checkbox',
        }).map(({key, type: collectionType, ...checkboxProps}) => (
          <Field
            key={key}
            data-invalid={fields.colors.errors ? true : undefined}
            orientation="horizontal"
          >
            <Checkbox {...checkboxProps} disabled={disabled} />
            <FieldLabel htmlFor={checkboxProps.id}>
              {colorLabels[checkboxProps.value as (typeof COLORS)[number]]}
            </FieldLabel>
          </Field>
        ))}
        <ConformFieldError field={fields.colors} />
      </FieldSet>

      <Field data-invalid={fields.size.errors ? true : undefined}>
        <FieldSet disabled={disabled}>
          <FieldLegend id={`${fields.size.id}-legend`} variant="label">
            {FIXTURE_TEXT.size}
          </FieldLegend>
          <RadioGroup
            aria-describedby={
              fields.size.errors ? fields.size.errorId : undefined
            }
            aria-invalid={fields.size.errors ? true : undefined}
            aria-labelledby={`${fields.size.id}-legend`}
            defaultValue={fields.size.initialValue}
            disabled={disabled}
            id={fields.size.id}
            name={fields.size.name}
            required={fields.size.required}
          >
            {SIZES_DISPLAY_ORDER.map((size) => (
              <Field
                key={size}
                data-invalid={fields.size.errors ? true : undefined}
                orientation="horizontal"
              >
                <RadioGroupItem id={`${fields.size.id}-${size}`} value={size} />
                <FieldLabel htmlFor={`${fields.size.id}-${size}`}>
                  {sizeLabels[size]}
                </FieldLabel>
              </Field>
            ))}
          </RadioGroup>
          <ConformFieldError field={fields.size} />
        </FieldSet>
      </Field>

      <Button disabled={disabled || isSubmitting} type="submit">
        {isSubmitting && <Spinner aria-hidden={true} />}
        {isSubmitting ? t('form.submitting') : t('form.submit')}
      </Button>
    </Form>
  );
};
