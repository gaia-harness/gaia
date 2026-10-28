import type {ComponentProps} from 'react';
import {parseWithZod} from '@conform-to/zod/v4';
import {expect, fn, waitFor, within} from 'storybook/test';
import stubs from 'test/stubs';
import preview from '#.storybook/preview';
import {ComposedForm, composedFormSchema} from './composed-form';

type PostedEntries = [string, string][];

type StoryArgs = ComponentProps<typeof ComposedForm> & {
  holdAction?: () => Promise<void>;
  isActionHeld?: boolean;
  onSubmit: (entries: PostedEntries) => void;
};

// The form posts to its own route, so the story observes the submission through
// the route's own action rather than a separate path.
const meta = preview.type<{args: StoryArgs}>().meta({
  args: {onSubmit: fn()},
  component: ComposedForm,
  decorators: [
    stubs.reactRouter(({args}) => {
      const {holdAction, isActionHeld, onSubmit} = args as StoryArgs;

      return {
        action: async ({request}) => {
          const formData = await request.formData();

          onSubmit(
            [...formData.entries()].map(([key, value]) => [key, String(value)])
          );

          // A held action never settles, so the pending state stays put for
          // the accessibility scan instead of racing the re-enable transition.
          if (isActionHeld) {
            await new Promise(() => {});
          }

          // A releasable hold keeps the pending state observable until the
          // play lets the action settle.
          await holdAction?.();

          return {
            result: parseWithZod(formData, {
              schema: composedFormSchema,
            }).reply(),
          };
        },
      };
    }),
  ],
  render: () => <ComposedForm />,
  title: 'Components/Form/ComposedForm',
});

export const Default = meta.story({});

export const Disabled = meta.story({
  render: () => <ComposedForm disabled={true} />,
});

const getColorCheckboxes = (canvasElement: HTMLElement): HTMLElement[] =>
  within(canvasElement).getAllByRole('checkbox', {name: /Blue|Green|Red/});

export const EmptySubmit = meta.story({
  play: async ({canvas, userEvent}) => {
    await userEvent.click(canvas.getByRole('button', {name: 'Submit'}));
  },
});

EmptySubmit.test(
  'marks every invalid control and ties it to its error',
  async ({canvas, canvasElement}) => {
    const invalidControls = [
      canvas.getByRole('textbox', {name: 'Name'}),
      ...getColorCheckboxes(canvasElement),
      canvas.getByRole('radiogroup', {name: 'Size'}),
    ];

    for (const control of invalidControls) {
      await waitFor(async () => {
        await expect(control).toHaveAttribute('aria-invalid', 'true');
      });

      const describedBy = (
        control.getAttribute('aria-describedby') ?? ''
      ).split(' ');
      const alertIds = canvas.getAllByRole('alert').map((alert) => alert.id);

      await expect(describedBy.some((id) => alertIds.includes(id))).toBe(true);

      const fieldGroups = canvas
        .getAllByRole('group')
        .filter(
          (group) => group.dataset.slot === 'field' && group.contains(control)
        );

      await expect(fieldGroups).not.toHaveLength(0);

      for (const group of fieldGroups) {
        await expect(group).toHaveAttribute('data-invalid', 'true');
      }
    }
  }
);

EmptySubmit.test(
  'flags only the name and size as required',
  async ({canvas, canvasElement}) => {
    await expect(canvas.getByRole('textbox', {name: 'Name'})).toBeRequired();
    await expect(canvas.getByRole('radiogroup', {name: 'Size'})).toBeRequired();

    for (const checkbox of getColorCheckboxes(canvasElement)) {
      await expect(checkbox).not.toBeRequired();
    }
  }
);

EmptySubmit.test('names the color and size groups', async ({canvas}) => {
  await expect(
    canvas.getByRole('group', {name: 'Favorite colors'})
  ).toBeVisible();
  await expect(canvas.getByRole('radiogroup', {name: 'Size'})).toBeVisible();
});

EmptySubmit.test(
  'moves focus to the first invalid control',
  async ({canvas}) => {
    await waitFor(async () => {
      await expect(canvas.getByRole('textbox', {name: 'Name'})).toHaveFocus();
    });
  }
);

Default.test(
  'toggles a control when its label is clicked',
  async ({canvas, userEvent}) => {
    for (const name of ['Blue', 'Green', 'Red']) {
      const checkbox = canvas.getByRole('checkbox', {name});

      await expect(checkbox).not.toBeChecked();
      await userEvent.click(canvas.getByText(name));
      await expect(checkbox).toBeChecked();
    }

    for (const name of ['Large', 'Medium', 'Small']) {
      await userEvent.click(canvas.getByText(name));
      await expect(canvas.getByRole('radio', {name})).toBeChecked();
    }
  }
);

Default.test(
  'toggles a checkbox with the space key',
  async ({canvas, userEvent}) => {
    const red = canvas.getByRole('checkbox', {name: 'Red'});
    const green = canvas.getByRole('checkbox', {name: 'Green'});

    red.focus();
    await userEvent.keyboard(' ');
    await expect(red).toBeChecked();

    await userEvent.tab();
    await expect(green).toHaveFocus();
    await userEvent.keyboard(' ');
    await expect(green).toBeChecked();
  }
);

Default.test(
  'moves the radio group with the arrow keys',
  async ({canvas, userEvent}) => {
    await userEvent.click(canvas.getByRole('radio', {name: 'Small'}));
    await expect(canvas.getByRole('radio', {name: 'Small'})).toHaveFocus();

    await userEvent.keyboard('{ArrowDown}');
    await expect(canvas.getByRole('radio', {name: 'Medium'})).toBeChecked();
    await expect(canvas.getByRole('radio', {name: 'Medium'})).toHaveFocus();

    await userEvent.tab();
    await expect(canvas.getByRole('radio', {name: 'Medium'})).not.toHaveFocus();
    await expect(canvas.getByRole('button', {name: 'Submit'})).toHaveFocus();
  }
);

// The submit button animates its opacity when its disabled state flips, and a
// scan taken mid-animation reads blended colors, so the play waits for the
// settled value.
const waitForSettledOpacity = async (button: HTMLElement, opacity: string) => {
  await waitFor(() => {
    if (getComputedStyle(button).opacity !== opacity) {
      throw new Error(`Submit button opacity has not settled to ${opacity}`);
    }
  });
};

let releaseAction: (() => void) | undefined;

export const FilledSubmit = meta.story({
  args: {
    holdAction: async () =>
      new Promise<void>((resolve) => {
        releaseAction = resolve;
      }),
  },
  play: async ({canvas, userEvent}) => {
    await userEvent.type(canvas.getByRole('textbox', {name: 'Name'}), 'Ada');
    await userEvent.type(
      canvas.getByRole('textbox', {name: 'Email'}),
      'ada@example.com'
    );
    await userEvent.type(canvas.getByLabelText('Password'), 'Secret123!');
    await userEvent.type(canvas.getByRole('textbox', {name: 'Bio'}), 'Hello');
    await userEvent.selectOptions(
      canvas.getByRole('combobox', {name: 'Country'}),
      'jp'
    );
    await userEvent.click(canvas.getByText('I accept the terms'));
    await userEvent.click(canvas.getByText('Blue'));
    await userEvent.click(canvas.getByText('Red'));
    await userEvent.click(canvas.getByText('Medium'));
    await userEvent.click(canvas.getByRole('button', {name: 'Submit'}));

    // The action is held, so the pending render is observable before the action
    // settles; release it only after that render committed, then wait for the
    // button to settle back to Submit.
    await canvas.findByRole('button', {name: /Please wait/});
    releaseAction?.();
    await waitForSettledOpacity(
      await canvas.findByRole('button', {name: 'Submit'}),
      '1'
    );
  },
});

FilledSubmit.test('posts every filled entry', async ({args}) => {
  await waitFor(async () => {
    await expect(args.onSubmit).toHaveBeenCalledWith([
      ['name', 'Ada'],
      ['email', 'ada@example.com'],
      ['password', 'Secret123!'],
      ['bio', 'Hello'],
      ['country', 'jp'],
      ['terms', 'on'],
      ['colors', 'red'],
      ['colors', 'blue'],
      ['size', 'md'],
    ]);
  });
});

export const SubmittingState = meta.story({
  args: {isActionHeld: true},
  play: async ({canvas, userEvent}) => {
    await userEvent.type(canvas.getByRole('textbox', {name: 'Name'}), 'Ada');
    await userEvent.click(canvas.getByText('Blue'));
    await userEvent.click(canvas.getByText('Medium'));
    await userEvent.click(canvas.getByRole('button', {name: 'Submit'}));

    const button = await canvas.findByRole('button', {name: /Please wait/});

    await waitForSettledOpacity(button, '0.5');
  },
});

SubmittingState.test(
  'disables the pending submit button and hides the spinner status',
  async ({canvas}) => {
    const button = await canvas.findByRole('button', {name: /Please wait/});

    await expect(button).toBeDisabled();
    await expect(canvas.getByRole('status', {hidden: true})).toHaveAttribute(
      'aria-hidden',
      'true'
    );
  }
);
