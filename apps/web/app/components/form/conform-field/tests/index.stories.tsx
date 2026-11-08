import {
  getFormProps,
  getInputProps,
  getSelectProps,
  getTextareaProps,
  useForm,
  useInputControl,
} from '@conform-to/react';
import {getZodConstraint, parseWithZod} from '@conform-to/zod/v4';
import {expect, waitFor} from 'storybook/test';
import {z} from 'zod';
import preview from '#.storybook/preview';
import {Button} from '~/components/ui/button';
import {Checkbox} from '~/components/ui/checkbox';
import {Input} from '~/components/ui/input';
import {NativeSelect, NativeSelectOption} from '~/components/ui/native-select';
import {Textarea} from '~/components/ui/textarea';
import {omitType} from '~/utils/object';
import ConformField from '..';

const schema = z.object({
  bio: z.string().optional(),
  email: z.email({error: 'email'}),
  nickname: z.string().optional(),
  plan: z.string().optional(),
  terms: z.boolean({error: 'required'}),
});

const DEFAULT_VALUE = {email: 'ada@example.com', nickname: 'Ada'};

const ExampleForm = () => {
  const [form, fields] = useForm<z.input<typeof schema>>({
    constraint: getZodConstraint(schema),
    defaultValue: DEFAULT_VALUE,
    onValidate: ({formData}) => parseWithZod(formData, {schema}),
  });
  const nicknameControl = useInputControl(fields.nickname);

  return (
    <form className="flex max-w-md flex-col gap-6" {...getFormProps(form)}>
      <ConformField
        description="We never share it"
        field={fields.email}
        label="Email"
      >
        {(controlOptions) => (
          <Input
            {...getInputProps(fields.email, {...controlOptions, type: 'email'})}
          />
        )}
      </ConformField>
      <ConformField field={fields.bio} label="Bio">
        {(controlOptions) => (
          <Textarea {...getTextareaProps(fields.bio, controlOptions)} />
        )}
      </ConformField>
      <ConformField field={fields.plan} label="Plan">
        {(controlOptions) => (
          <NativeSelect {...getSelectProps(fields.plan, controlOptions)}>
            <NativeSelectOption value="">None</NativeSelectOption>
          </NativeSelect>
        )}
      </ConformField>
      <ConformField field={fields.nickname} label="Nickname">
        {(controlOptions) => (
          <Input
            {...getInputProps(fields.nickname, {
              ...controlOptions,
              type: 'text',
              value: false,
            })}
            onBlur={nicknameControl.blur}
            onChange={(event) => {
              nicknameControl.change(event.target.value);
            }}
            value={nicknameControl.value ?? ''}
          />
        )}
      </ConformField>
      <ConformField
        field={fields.terms}
        label="I accept the terms"
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
          />
        )}
      </ConformField>
      <Button type="submit">Submit</Button>
      <Button type="submit" variant="outline" {...form.reset.getButtonProps()}>
        Reset
      </Button>
    </form>
  );
};

const listSchema = z.object({tasks: z.array(z.string())});

// A row keyed by its name keeps its position through a removal, so only the key
// on the control tells React the value in that position has changed.
const ListForm = () => {
  const [form, fields] = useForm<z.input<typeof listSchema>>({
    defaultValue: {tasks: ['First', 'Second']},
    onValidate: ({formData}) => parseWithZod(formData, {schema: listSchema}),
  });

  return (
    <form className="flex max-w-md flex-col gap-6" {...getFormProps(form)}>
      {fields.tasks.getFieldList().map((task, index) => (
        <div key={task.name} className="flex flex-col gap-2">
          <ConformField field={task} label={`Task ${index + 1}`}>
            {(controlOptions) => (
              <Input
                {...getInputProps(task, {...controlOptions, type: 'text'})}
              />
            )}
          </ConformField>
          <Button
            type="submit"
            variant="outline"
            {...form.remove.getButtonProps({
              index,
              name: fields.tasks.name,
            })}
          >
            {`Remove task ${index + 1}`}
          </Button>
        </div>
      ))}
    </form>
  );
};

const meta = preview.meta({
  component: ExampleForm,
  parameters: {wrap: 'p-4'},
  title: 'Components/Form/ConformField',
});

export const Default = meta.story({});

Default.test(
  'links the label and the description to the control',
  async ({canvas}) => {
    const email = canvas.getByRole('textbox', {name: 'Email'});

    await expect(email).toBeRequired();
    await expect(email).toHaveAccessibleDescription('We never share it');
    await expect(
      canvas.getByRole('textbox', {name: 'Bio'})
    ).not.toHaveAttribute('aria-describedby');
  }
);

Default.test(
  'restores uncontrolled, controlled and stateful controls on reset',
  async ({canvas, userEvent}) => {
    const email = canvas.getByRole('textbox', {name: 'Email'});
    const nickname = canvas.getByRole('textbox', {name: 'Nickname'});
    const terms = canvas.getByRole('checkbox', {name: 'I accept the terms'});

    await userEvent.clear(email);
    await userEvent.type(email, 'grace@example.com');
    await userEvent.clear(nickname);
    await userEvent.type(nickname, 'Grace');
    await userEvent.click(terms);
    await expect(terms).toBeChecked();

    await userEvent.click(canvas.getByRole('button', {name: 'Reset'}));

    await waitFor(async () => {
      await expect(canvas.getByRole('textbox', {name: 'Email'})).toHaveValue(
        DEFAULT_VALUE.email
      );
      await expect(canvas.getByRole('textbox', {name: 'Nickname'})).toHaveValue(
        DEFAULT_VALUE.nickname
      );
      await expect(
        canvas.getByRole('checkbox', {name: 'I accept the terms'})
      ).not.toBeChecked();
    });
  }
);

export const FieldList = meta.story({
  render: () => <ListForm />,
});

FieldList.test(
  'shows the next value in a row whose field was removed',
  async ({canvas, userEvent}) => {
    await userEvent.click(canvas.getByRole('button', {name: 'Remove task 1'}));

    await waitFor(async () => {
      await expect(canvas.getByRole('textbox', {name: 'Task 1'})).toHaveValue(
        'Second'
      );
    });
  }
);

export const WithError = meta.story({
  play: async ({canvas, userEvent}) => {
    await userEvent.clear(canvas.getByRole('textbox', {name: 'Email'}));
    await userEvent.type(
      canvas.getByRole('textbox', {name: 'Email'}),
      'not-an-email'
    );
    await userEvent.click(canvas.getByRole('button', {name: 'Submit'}));
    await canvas.findAllByRole('alert');
  },
});

WithError.test(
  'marks the control invalid and describes it by both its help and its error',
  async ({canvas}) => {
    const email = canvas.getByRole('textbox', {name: 'Email'});

    await expect(email).toHaveAttribute('aria-invalid', 'true');
    await expect(email).toHaveAccessibleDescription(/Email is invalid/);
    await expect(email).toHaveAccessibleDescription(/We never share it/);
    const emailLabel = canvas.getByText('Email');
    const validLabel = canvas.getByText('Bio');

    await expect(getComputedStyle(emailLabel).color).not.toBe(
      getComputedStyle(validLabel).color
    );
  }
);

WithError.test(
  'links the error of a control rendered before its label',
  async ({canvas}) => {
    const terms = canvas.getByRole('checkbox', {name: 'I accept the terms'});

    await expect(terms).toHaveAttribute('aria-invalid', 'true');
    await expect(terms).toHaveAccessibleDescription('Required');
  }
);
