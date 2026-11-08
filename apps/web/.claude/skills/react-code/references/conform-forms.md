# Conform + Zod Form Wiring

Wrap each standalone control in `ConformField` (`~/components/form/conform-field`). You write the control and spread Conform's props on it; the wrapper does the rest. A hand-wired `Field` around one control is an audit finding. Import Conform's Zod helpers from `@conform-to/zod/v4` (react-code Gate 2); the examples use `/v4` throughout.

Contents: One control: ConformField; Commonly missed; Form setup; Groups stay composed; Actions and disabled states; Zod Patterns.

## One control: ConformField

```tsx
import {getInputProps} from '@conform-to/react';
import ConformField from '~/components/form/conform-field';
import {Input} from '~/components/ui/input';

<ConformField
  description={t('emailDescription')}
  field={fields.email}
  label={t('email')}
>
  {(controlOptions) => (
    <Input {...getInputProps(fields.email, {...controlOptions, type: 'email'})} />
  )}
</ConformField>;
```

The child function receives `controlOptions`; always pass them to Conform's getter, because they link the description to `aria-describedby`.

| Control | Child |
| --- | --- |
| `ui/input` | `<Input {...getInputProps(field, {...controlOptions, type: 'email'})} />` |
| `ui/textarea` | `<Textarea {...getTextareaProps(field, controlOptions)} />` |
| `ui/native-select` | `<NativeSelect {...getSelectProps(field, controlOptions)}>` with its options |
| `ui/checkbox`, alone | `<Checkbox {...omitType(getInputProps(field, {...controlOptions, type: 'checkbox'}))} />` with `orientation="horizontal"` on `ConformField`, which puts the control before its label |
| Stateful custom control | `getInputProps(field, {...controlOptions, type: 'text', value: false})` with `useInputControl` supplying `value`, `onChange` and `onBlur` |

`omitType` from `~/utils/object` strips Conform's `type`, an input attribute the Base UI checkbox root does not take.

**What it wires:** `data-invalid`, the label's `htmlFor`, the description's id, the errors and the control's `key`. Conform's getter supplies `id`, `name`, `aria-invalid`, `aria-describedby`, and `required`.

**Error messages:** a schema message is a key in `errors.validation` in the language files. `ConformFieldError`, which `ConformField` renders, translates it. A message with no key there shows as written, so a missing translation key appears as its raw key, and a translated server error passes through.

## Commonly missed

Scenarios that fail with no error. A new miss goes in `ConformField` if the wrapper can absorb it; otherwise it becomes an audit check and an entry here.

| Scenario | What silently goes wrong | Fix |
| --- | --- | --- |
| `useForm` without `constraint`, in any form with a schema | No control is marked required, so assistive technology never announces it | `constraint: getZodConstraint(schema)` |
| A composed control rendered from `getFieldList()` not keyed by `field.key` | After a list `remove`, `insert` or `reorder`, a row keyed by position shows the old value | `key={field.key}` on the control or its row |
| A group's `FieldError` fed Conform's messages as `{message}` objects, or through a page-local mapper | A schema key shows raw, or a map miss shows nothing | `<ConformFieldError field={field} />` |
| A `RadioGroup` missing Conform's attributes, which no getter supplies for it | Screen readers get no invalid state, error link or required state | Set `aria-invalid`, `aria-describedby` and `required={field.required}` as `### Radio group` shows |

## Form setup

### 1. Define the Zod schema (in the route file)

```tsx
const schema = z.object({
  colors: z.array(z.literal(['blue', 'green', 'red'])).min(1, 'required'),
  name: z.string().min(1, 'required'),
  size: z.literal(['lg', 'md', 'sm']),
});
```

### 2. Action (in the route file)

```tsx
// import type {Route} from './+types/<route-file>';
export const action = async ({request}: Route.ActionArgs) => {
  const formData = await request.formData();
  const submission = parseWithZod(formData, {schema});

  if (submission.status !== 'success') {
    return data({result: submission.reply()});
  }

  // Pass only submission.value to the service's request function
  await createUser(submission.value);
  return redirect('/users');
};
```

An action validates with `parseWithZod` (from `@conform-to/zod/v4`) against the same input schema the service's mutation takes, and passes only `submission.value` to the request function; ids come from route params.

### 3. Page component with `useForm`

```tsx
import {useTranslation} from 'react-i18next';
import {Form, useActionData, useNavigation} from 'react-router';
import type {SubmissionResult} from '@conform-to/react';
import {getFormProps, useForm} from '@conform-to/react';
import {getZodConstraint, parseWithZod} from '@conform-to/zod/v4';
import {Button} from '~/components/ui/button';
import {Spinner} from '~/components/ui/spinner';

const MyPage = () => {
  const {t} = useTranslation('pages');
  const actionData = useActionData<{result: SubmissionResult}>();
  const navigation = useNavigation();
  const isSubmitting = navigation.state === 'submitting';

  const [form, fields] = useForm({
    constraint: getZodConstraint(schema),
    lastResult: actionData?.result,
    onValidate: ({formData}) => parseWithZod(formData, {schema}),
    shouldRevalidate: 'onInput',
    shouldValidate: 'onBlur',
  });

  return (
    <Form method="post" {...getFormProps(form)}>
      {/* one ConformField per control, a composed group per group */}
      <Button disabled={isSubmitting} type="submit">
        {isSubmitting && <Spinner aria-label={t('submitting')} />}
        {t('save')}
      </Button>
    </Form>
  );
};
```

## Groups stay composed

A group is named by a legend, which `FieldLabel htmlFor` cannot do, and it renders one control per option, so it is built from the ui `Field` parts with `ConformFieldError` for its errors.

### Checkbox group

`FieldSet` and `FieldLegend` around one `ui/checkbox` per option, each from `getCollectionProps`. Conform's `type` is an input attribute the Base UI checkbox root does not take, so drop it:

```tsx
import {getCollectionProps} from '@conform-to/react';
import ConformFieldError from '~/components/form/conform-field-error';
import {Checkbox} from '~/components/ui/checkbox';
import {
  Field,
  FieldDescription,
  FieldLabel,
  FieldLegend,
  FieldSet,
} from '~/components/ui/field';

<FieldSet aria-describedby={fields.colors.descriptionId}>
  <FieldLegend variant="label">{t('colors')}</FieldLegend>
  <FieldDescription id={fields.colors.descriptionId}>
    {t('colorsDescription')}
  </FieldDescription>
  {getCollectionProps(fields.colors, {
    options: COLORS,
    type: 'checkbox',
  }).map(({key, type: _type, ...checkboxProps}) => (
    <Field
      key={key}
      data-invalid={fields.colors.errors ? true : undefined}
      orientation="horizontal"
    >
      <Checkbox {...checkboxProps} />
      <FieldLabel htmlFor={checkboxProps.id}>{colorLabels[checkboxProps.value]}</FieldLabel>
    </Field>
  ))}
  <ConformFieldError field={fields.colors} />
</FieldSet>;
```

### Radio group

`ui/radio-group` in a `FieldSet` and `FieldLegend`, given `name` and `defaultValue` from Conform and labelled by the legend (Conform has no radio-group props helper, so the invalid and described-by attributes are set by hand):

```tsx
import ConformFieldError from '~/components/form/conform-field-error';
import {
  Field,
  FieldDescription,
  FieldLabel,
  FieldLegend,
  FieldSet,
} from '~/components/ui/field';
import {RadioGroup, RadioGroupItem} from '~/components/ui/radio-group';

<Field data-invalid={fields.size.errors ? true : undefined}>
  <FieldSet>
    <FieldLegend id={`${fields.size.id}-legend`} variant="label">
      {t('size')}
    </FieldLegend>
    <FieldDescription id={fields.size.descriptionId}>
      {t('sizeDescription')}
    </FieldDescription>
    <RadioGroup
      aria-describedby={
        fields.size.errors
          ? `${fields.size.descriptionId} ${fields.size.errorId}`
          : fields.size.descriptionId
      }
      aria-invalid={fields.size.errors ? true : undefined}
      aria-labelledby={`${fields.size.id}-legend`}
      defaultValue={fields.size.initialValue}
      id={fields.size.id}
      name={fields.size.name}
      required={fields.size.required}
    >
      {SIZES.map((size) => (
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
</Field>;
```

## Actions and disabled states

A disabled action renders a disabled `ui/button`, never a disabled link: `<Button disabled>` keeps the button role and the disabled semantics, while an `<a>` cannot be disabled and a styled link stays focusable and clickable. Pass `disabled` to the controls and the `FieldSet` together when a whole form is disabled. A button that navigates is `<Button nativeButton={false} render={<Link to="/path" role="link" />}>`; Base UI sets `role="button"` on a non-native render target, so the explicit `role="link"` restores the link role.

## Zod Patterns

This project uses Zod 4, the typescript skill's `references/zod.md` is the full Zod 3 → Zod 4 migration map. Project convention: `z.literal([...])` not `z.enum()` for string unions (sort values alphanumerically).
