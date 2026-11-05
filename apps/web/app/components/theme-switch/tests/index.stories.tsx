import {expect, fn, userEvent, waitFor} from 'storybook/test';
import stubs from 'test/stubs';
import preview from '#.storybook/preview';
import {ACTION_PATHS} from '~/action-paths';
import ThemeSwitch from '..';
import type {ThemeSwitchProps} from '..';

type StoryArgs = ThemeSwitchProps & {
  onSubmit: (theme: FormDataEntryValue | null) => void;
};

const meta = preview.type<{args: StoryArgs}>().meta({
  args: {onSubmit: fn()},
  component: ThemeSwitch,
  decorators: [
    stubs.reactRouter(({args}) => ({
      actions: {
        [ACTION_PATHS.themeSwitch]: async ({request}) => {
          const formData = await request.formData();

          args.onSubmit(formData.get('theme'));

          return null;
        },
      },
    })),
  ],
  parameters: {
    wrap: 'p-4',
  },
  render: ({userPreference}) => <ThemeSwitch userPreference={userPreference} />,
  title: 'Components/ThemeSwitch',
});

export const Default = meta.story({});

Default.test(
  'posts light when activated by keyboard',
  async ({args, canvas}) => {
    const button = await canvas.findByRole('button', {
      name: 'Enable light mode',
    });

    await userEvent.tab();
    await expect(button).toHaveFocus();

    await userEvent.keyboard('{Enter}');

    await waitFor(async () => {
      await expect(args.onSubmit).toHaveBeenCalledTimes(1);
    });
    await expect(args.onSubmit).toHaveBeenCalledWith('light');
  }
);

export const Light = meta.story({
  args: {userPreference: 'light'},
});

export const Dark = meta.story({
  args: {userPreference: 'dark'},
});

export const Cycle = meta.story({
  render: () => (
    <div className="flex gap-2">
      <ThemeSwitch />
      <ThemeSwitch userPreference="light" />
      <ThemeSwitch userPreference="dark" />
    </div>
  ),
});

Cycle.test(
  'offers the next theme at each step and posts it when clicked',
  async ({args, canvas}) => {
    const steps = [
      {name: 'Enable light mode', next: 'light'},
      {name: 'Enable dark mode', next: 'dark'},
      {name: 'Use system theme', next: 'system'},
    ];

    for (const [index, {name, next}] of steps.entries()) {
      await userEvent.click(await canvas.findByRole('button', {name}));

      await waitFor(async () => {
        await expect(args.onSubmit).toHaveBeenCalledTimes(index + 1);
      });

      await expect(args.onSubmit).toHaveBeenLastCalledWith(next);
    }
  }
);
