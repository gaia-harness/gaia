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

const expectIconAndPost = async ({
  args,
  canvas,
  icon,
  name,
  next,
}: {
  args: StoryArgs;
  canvas: ReturnType<typeof within>;
  icon: string;
  name: string;
  next: string;
}) => {
  const button = await canvas.findByRole('button', {name});

  // Icons are aria-hidden, so the lucide class is the only handle on them.
  await expect(button.querySelector(`svg.lucide-${icon}`)).toBeInTheDocument();

  await userEvent.click(button);

  await waitFor(async () => {
    await expect(args.onSubmit).toHaveBeenCalledTimes(1);
  });
  await expect(args.onSubmit).toHaveBeenCalledWith(next);
};

export const Default = meta.story({});

Default.test(
  'shows the monitor icon and posts light when clicked',
  async ({args, canvas}) =>
    expectIconAndPost({
      args,
      canvas,
      icon: 'monitor',
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
  'shows the sun icon and posts dark when clicked',
  async ({args, canvas}) =>
    expectIconAndPost({
      args,
      canvas,
      icon: 'sun',
      name: 'Enable dark mode',
      next: 'dark',
    })
);

export const Dark = meta.story({
  args: {userPreference: 'dark'},
});

Dark.test(
  'shows the moon icon and posts system when clicked',
  async ({args, canvas}) =>
    expectIconAndPost({
      args,
      canvas,
      icon: 'moon',
      name: 'Use system theme',
      next: 'system',
    })
);

// i18next's built-in `cimode` locale renders each translation key, so the
// test finds the key only once i18next has switched to the story's locale
// global before render.
export const LocaleGlobal = meta.story({
  globals: {locale: 'cimode'},
});

LocaleGlobal.test(
  'renders the translation key for the button name',
  async ({canvas}) => {
    await expect(
      canvas.getByRole('button', {
        name: 'theme.enableLightMode',
      })
    ).toBeInTheDocument();
  }
);
