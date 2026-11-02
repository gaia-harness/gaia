import {expect, fireEvent, fn, waitFor} from 'storybook/test';
import stubs from 'test/stubs';
import preview from '#.storybook/preview';
import {ACTION_PATHS} from '~/action-paths';
import LanguageSelect from '..';

type StoryArgs = {
  actionDelayMilliseconds: number;
  languages: string[];
  onSubmit: (language: FormDataEntryValue | null) => void;
};

const meta = preview.type<{args: StoryArgs}>().meta({
  args: {
    actionDelayMilliseconds: 0,
    languages: ['en', 'ja'],
    onSubmit: fn(),
  },
  component: LanguageSelect,
  decorators: [
    stubs.reactRouter(({args}) => ({
      actions: {
        [ACTION_PATHS.setLanguage]: async ({request}) => {
          const formData = await request.formData();

          if (args.actionDelayMilliseconds) {
            await new Promise((resolve) => {
              setTimeout(resolve, args.actionDelayMilliseconds);
            });
          }

          args.onSubmit(formData.get('language'));

          return null;
        },
      },
    })),
  ],
  parameters: {
    wrap: 'p-4',
  },
  render: ({languages}) => <LanguageSelect languages={languages} />,
  title: 'Components/LanguageSelect',
});

// Long enough for a stray submission to reach the action before asserting none did.
const SETTLE_MILLISECONDS = 50;

const settle = async () =>
  new Promise((resolve) => {
    setTimeout(resolve, SETTLE_MILLISECONDS);
  });

const findSelect = async (canvas: {
  findByRole: (role: string, options: {name: string}) => Promise<HTMLElement>;
}) => canvas.findByRole('combobox', {name: 'Language'});

// A closed native select changes value on Arrow keys (Windows browsers), and
// Chromium's closed-select arrow behavior is platform-dependent, so the keyboard
// path is a keydown followed by the change it causes.
const arrowTo = async (select: HTMLElement, value: string) => {
  await fireEvent.keyDown(select, {key: 'ArrowDown'});
  await fireEvent.change(select, {target: {value}});
};

const expectSubmittedOnce = async (
  onSubmit: StoryArgs['onSubmit'],
  language: string
) => {
  await waitFor(async () => {
    await expect(onSubmit).toHaveBeenCalledTimes(1);
  });
  await expect(onSubmit).toHaveBeenCalledWith(language);
};

export const Default = meta.story({});

Default.test(
  'submits when a language is chosen with the pointer',
  async ({args, canvas, userEvent}) => {
    const select = await findSelect(canvas);

    await userEvent.selectOptions(select, 'ja');

    await expectSubmittedOnce(args.onSubmit, 'ja');
  }
);

Default.test(
  'does not submit when an arrow key only moves the selection',
  async ({args, canvas}) => {
    const select = await findSelect(canvas);

    await arrowTo(select, 'ja');

    await settle();
    await expect(args.onSubmit).not.toHaveBeenCalled();
  }
);

Default.test('submits on Enter', async ({args, canvas, userEvent}) => {
  const select = await findSelect(canvas);

  await userEvent.tab();
  await expect(select).toHaveFocus();
  await arrowTo(select, 'ja');
  await userEvent.keyboard('{Enter}');

  await expectSubmittedOnce(args.onSubmit, 'ja');
});

Default.test(
  'submits on leaving the select',
  async ({args, canvas, userEvent}) => {
    const select = await findSelect(canvas);

    await userEvent.tab();
    await expect(select).toHaveFocus();
    await arrowTo(select, 'ja');
    await userEvent.tab();
    await expect(select).not.toHaveFocus();

    await expectSubmittedOnce(args.onSubmit, 'ja');
  }
);

Default.test(
  'submits once when Enter is followed by leaving',
  async ({args, canvas, userEvent}) => {
    const select = await findSelect(canvas);

    select.focus();
    await arrowTo(select, 'ja');
    await userEvent.keyboard('{Enter}');
    await expectSubmittedOnce(args.onSubmit, 'ja');
    await userEvent.tab();

    await settle();
    await expect(args.onSubmit).toHaveBeenCalledTimes(1);
  }
);

Default.test(
  'does not submit when leaving back on the current language',
  async ({args, canvas, userEvent}) => {
    const select = await findSelect(canvas);

    select.focus();
    await arrowTo(select, 'ja');
    await arrowTo(select, 'en');
    await userEvent.tab();

    await settle();
    await expect(args.onSubmit).not.toHaveBeenCalled();
  }
);

Default.test(
  'submits a pointer choice made after an arrow keydown',
  async ({args, canvas, userEvent}) => {
    const select = await findSelect(canvas);

    await fireEvent.keyDown(select, {key: 'ArrowDown'});
    await userEvent.selectOptions(select, 'ja');

    await expectSubmittedOnce(args.onSubmit, 'ja');
  }
);

export const InFlightSubmit = meta.story({
  args: {actionDelayMilliseconds: SETTLE_MILLISECONDS},
});

InFlightSubmit.test(
  'submits the latest choice when it changes during an in-flight submit',
  async ({args, canvas, userEvent}) => {
    const select = await findSelect(canvas);

    await userEvent.selectOptions(select, 'ja');
    await userEvent.selectOptions(select, 'en');

    await waitFor(async () => {
      await expect(args.onSubmit).toHaveBeenLastCalledWith('en');
    });
  }
);
