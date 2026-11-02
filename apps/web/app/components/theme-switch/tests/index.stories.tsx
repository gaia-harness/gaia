import {expect, fn, userEvent, waitFor} from 'storybook/test';
import type {within} from 'storybook/test';
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

const expectNameAndPost = async ({
  args,
  canvas,
  name,
  next,
}: {
  args: StoryArgs;
  canvas: ReturnType<typeof within>;
  name: string;
  next: string;
}) => {
  await userEvent.click(await canvas.findByRole('button', {name}));

  await waitFor(async () => {
    await expect(args.onSubmit).toHaveBeenCalledTimes(1);
  });
  await expect(args.onSubmit).toHaveBeenCalledWith(next);
};

export const Default = meta.story({});

Default.test(
  'offers light mode from the system default and posts light when clicked',
  async ({args, canvas}) =>
    expectNameAndPost({
      args,
      canvas,
      name: 'Enable light mode',
      next: 'light',
    })
);

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

Light.test(
  'offers dark mode from light and posts dark when clicked',
  async ({args, canvas}) =>
    expectNameAndPost({
      args,
      canvas,
      name: 'Enable dark mode',
      next: 'dark',
    })
);

export const Dark = meta.story({
  args: {userPreference: 'dark'},
});

Dark.test(
  'offers the system theme from dark and posts system when clicked',
  async ({args, canvas}) =>
    expectNameAndPost({
      args,
      canvas,
      name: 'Use system theme',
      next: 'system',
    })
);
