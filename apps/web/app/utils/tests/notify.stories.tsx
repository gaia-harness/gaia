import {expect, spyOn, waitFor, within} from 'storybook/test';
import {
  computeContrastRatio,
  MINIMUM_NON_TEXT_CONTRAST,
  resolveColor,
} from 'test/contrast';
import preview from '#.storybook/preview';
import {toast} from '~/components/ui/toast';
import {notify, NOTIFY_TYPES} from '~/utils/notify';
import {expectToast} from './expect-toast';
import stack from './stack';

// The toast renders in a portal on the document body, outside the canvas.
const getToastElement = (canvasElement: HTMLElement, title: string) =>
  within(canvasElement.ownerDocument.body).getByRole('dialog', {name: title});

const readDestructiveColor = (): string => {
  const probe = document.createElement('span');
  probe.style.color = 'var(--destructive)';
  document.body.append(probe);
  const {color} = getComputedStyle(probe);
  probe.remove();

  return color;
};

// Toasts live in a module-level manager, so one story's toasts reach the next.
// Closing them and waiting for them to unmount keeps each story's toast
// count, and the axe scan after its play, to that story alone.
const clearToasts = async (): Promise<void> => {
  toast.close();
  await waitFor(async () => {
    await expect(
      document.body.querySelectorAll('[data-slot="toast"]')
    ).toHaveLength(0);
  });
};

const meta = preview.meta({
  beforeEach: clearToasts,
  // The toast renders in a portal outside the canvas, so the canvas carries a
  // caption of its own: the story scan requires content in the story root.
  component: () => (
    <p className="text-sm">Notifications appear bottom right.</p>
  ),
  parameters: {
    wrap: 'p-4',
  },
  title: 'Utils/Notify',
});

export const ErrorToast = meta.story({
  play: async ({canvasElement}) => {
    notify.error({
      description: 'The server could not save your changes.',
      message: 'Something went wrong',
    });

    await expectToast(canvasElement, 'Something went wrong');
  },
});

export const Info = meta.story({
  play: async ({canvasElement}) => {
    notify.info({
      description: 'A new version of the app is available.',
      message: 'Update available',
    });

    await expectToast(canvasElement, 'Update available');
  },
});

export const Success = meta.story({
  play: async ({canvasElement}) => {
    notify.success({
      description: 'Your changes have been saved.',
      message: 'Saved',
    });

    await expectToast(canvasElement, 'Saved');
  },
});

export const Warning = meta.story({
  play: async ({canvasElement}) => {
    notify.warning('Your session expires in five minutes');

    await expectToast(canvasElement, 'Your session expires in five minutes');
  },
});

export const WithStack = meta.story({
  play: async ({canvasElement}) => {
    // Development builds log the stack on purpose; the test below asserts it.
    const consoleError = spyOn(console, 'error').mockImplementation(
      () => undefined
    );
    notify.error({
      message: JSON.stringify({
        description: 'The stack trace is logged to the console in development',
        message: 'Error with stack trace',
        stack,
      }),
    });
    consoleError.mockRestore();

    await expectToast(canvasElement, 'Error with stack trace');
  },
});

WithStack.test(
  'logs the stack but does not show it',
  async ({canvasElement}) => {
    await clearToasts();

    const consoleError = spyOn(console, 'error').mockImplementation(
      () => undefined
    );
    const body = within(canvasElement.ownerDocument.body);
    notify.error({
      message: JSON.stringify({
        description: 'Expand to view the stack',
        message: 'Stacked and logged',
        stack,
      }),
    });

    await expectToast(canvasElement, 'Stacked and logged');
    await expect(body.getByText('Expand to view the stack')).toBeVisible();

    // Production builds, which Chromatic snapshots, never log the stack.
    if (process.env.NODE_ENV === 'production') {
      await expect(consoleError).not.toHaveBeenCalledWith(stack);
    } else {
      await expect(consoleError).toHaveBeenCalledWith(stack);
    }
    // A substring check, so a stack rendered as one block still fails it.
    await expect(canvasElement.ownerDocument.body).not.toHaveTextContent(
      stack.split('\n', 1)[0]
    );
    consoleError.mockRestore();
  }
);

export const StringAndDescriptionPayloads = meta.story({
  play: async ({canvasElement}) => {
    const body = within(canvasElement.ownerDocument.body);
    notify.info('plain string payload');
    notify.success({
      description: 'with description payload',
      message: 'Titled payload',
    });

    // Waits for the toasts: getByText throws until each one is on screen.
    await waitFor(() => {
      body.getByText('plain string payload');
      body.getByText('Titled payload');
      body.getByText('with description payload');
    });
  },
});

export const DescriptionOnlyPromoted = meta.story({
  play: async ({canvasElement}) => {
    notify.warning({description: 'only a description'});

    await expectToast(canvasElement, 'only a description');
  },
});

DescriptionOnlyPromoted.test(
  'promotes the description to the title when there is no message',
  async ({canvasElement}) => {
    const payloads = [
      {description: 'only a description'},
      {description: 'Saved empty message', message: ''},
    ];

    for (const payload of payloads) {
      await clearToasts();
      notify.warning(payload);

      await expectToast(canvasElement, payload.description);
      await expect(
        getToastElement(canvasElement, payload.description)
      ).not.toHaveAccessibleDescription();
    }
  }
);

export const MessageRenderedAsText = meta.story({
  play: async ({canvasElement}) => {
    notify.info('<img src=x onerror="alert(1)">');

    await expectToast(canvasElement, '<img src=x onerror="alert(1)">');
  },
});

MessageRenderedAsText.test(
  'renders markup in a message as text',
  async ({canvasElement}) => {
    await expect(
      within(canvasElement.ownerDocument.body).queryByRole('img')
    ).not.toBeInTheDocument();
  }
);

Info.test(
  'gives each notification type a distinct icon',
  async ({canvasElement}) => {
    const drawings: string[] = [];

    for (const type of NOTIFY_TYPES) {
      await clearToasts();
      notify[type](`${type} icon message`);

      await expectToast(canvasElement, `${type} icon message`);

      // The icon is aria-hidden, so it is reached through its toast's icon
      // slot. The svg's child shapes are its drawing, whatever the icon
      // library names its classes.
      const icon = getToastElement(
        canvasElement,
        `${type} icon message`
      ).querySelector('[data-slot="toast-icon"] svg');

      await expect(icon).not.toBeNull();
      drawings.push(icon?.innerHTML ?? '');
    }

    await expect(new Set(drawings).size).toBe(NOTIFY_TYPES.length);
  }
);

Info.test('colors only the error icon destructive', async ({canvasElement}) => {
  await clearToasts();
  notify.error('destructive error message');

  await expectToast(canvasElement, 'destructive error message');

  const errorIcon = getToastElement(
    canvasElement,
    'destructive error message'
  ).querySelector('[data-slot="toast-icon"] svg');

  // Read while the toast is on screen: a closed toast's icon has no style.
  const errorColor = getComputedStyle(errorIcon as Element).color;

  await clearToasts();
  notify.info('plain info message');

  await expectToast(canvasElement, 'plain info message');

  const infoIcon = getToastElement(
    canvasElement,
    'plain info message'
  ).querySelector('[data-slot="toast-icon"] svg');

  const destructive = readDestructiveColor();

  await expect(errorColor).toBe(destructive);
  await expect(getComputedStyle(infoIcon as Element).color).not.toBe(
    destructive
  );
});

Info.test(
  'updates one toast for a repeated payload',
  async ({canvasElement}) => {
    await clearToasts();

    const body = within(canvasElement.ownerDocument.body);
    notify.info('repeat me payload');

    notify.info('repeat me payload');

    await expectToast(canvasElement, 'repeat me payload');
    await waitFor(async () => {
      await expect(body.getAllByText('repeat me payload')).toHaveLength(1);
    });
  }
);

// The storybook project runs this in light and the storybook-dark project in
// dark, so both themes are measured.
Info.test(
  'gives each toast icon 3:1 contrast against its surface',
  async ({canvasElement}) => {
    for (const type of NOTIFY_TYPES) {
      await clearToasts();
      notify[type](`${type} contrast message`);

      await expectToast(canvasElement, `${type} contrast message`);

      const toastElement = getToastElement(
        canvasElement,
        `${type} contrast message`
      );
      const icon = toastElement.querySelector('[data-slot="toast-icon"] svg');

      await expect(icon).not.toBeNull();
      const surface = resolveColor(
        getComputedStyle(toastElement).backgroundColor,
        getComputedStyle(document.body).backgroundColor
      );
      const iconColor = resolveColor(
        getComputedStyle(icon as Element).color,
        getComputedStyle(toastElement).backgroundColor
      );

      await expect(
        computeContrastRatio(iconColor, surface),
        `${type} toast icon contrast`
      ).toBeGreaterThanOrEqual(MINIMUM_NON_TEXT_CONTRAST);
    }
  }
);
