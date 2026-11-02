import {expect, fn, waitFor, within} from 'storybook/test';
import preview from '#.storybook/preview';
import {toast, Toaster} from '~/components/ui/toast';

// The global ToastDecorator already renders the Toaster, so each story fires a
// toast through the ui toast manager rather than mounting a second, empty
// Toaster. The per-type toasts the app sends live in the Utils/Notify stories;
// these cover the manager calls notify does not wrap.
const meta = preview.meta({
  component: Toaster,
  parameters: {
    wrap: 'p-4',
  },
  render: () => <div />,
  title: 'Components/Ui/Toast',
});

// A play only puts the toast on screen so the snapshot shows it; the toast
// renders in a portal on the document body, outside the canvas element.
const findToast = async (canvasElement: HTMLElement, text: string) =>
  within(canvasElement.ownerDocument.body).findByText(text);

const onUndo = fn();

export const Default = meta.story({
  play: async ({canvasElement}) => {
    toast.add({
      description: 'Monday, January 3rd at 6:00pm',
      title: 'Event created',
    });

    await findToast(canvasElement, 'Event created');
  },
});

export const WithAction = meta.story({
  play: async ({canvasElement}) => {
    toast.add({
      actionProps: {children: 'Undo', onClick: onUndo},
      title: 'Message archived',
    });

    await findToast(canvasElement, 'Message archived');
  },
});

WithAction.test(
  'fires the action on click',
  async ({canvasElement, userEvent}) => {
    await userEvent.click(
      within(canvasElement.ownerDocument.body).getByRole('button', {
        name: 'Undo',
      })
    );

    await expect(onUndo).toHaveBeenCalledOnce();
  }
);

WithAction.test(
  'fires the action from the keyboard',
  async ({canvasElement, userEvent}) => {
    const body = within(canvasElement.ownerDocument.body);

    // The toast itself takes focus first, then its controls in order.
    await userEvent.tab();
    await expect(body.getByRole('dialog')).toHaveFocus();
    await userEvent.tab();
    await expect(body.getByRole('button', {name: 'Undo'})).toHaveFocus();

    await userEvent.keyboard('{Enter}');

    await expect(onUndo).toHaveBeenCalledOnce();
  }
);

WithAction.test(
  'closes the toast from the keyboard',
  async ({canvasElement, userEvent}) => {
    const body = within(canvasElement.ownerDocument.body);

    await userEvent.tab();
    await userEvent.tab();
    await userEvent.tab();
    // Close stays hidden from assistive technology until focus enters the
    // toast, so it is queried only once focus has reached it.
    await expect(body.getByRole('button', {name: 'Close toast'})).toHaveFocus();

    await userEvent.keyboard('{Enter}');

    await waitFor(async () => {
      await expect(
        body.queryByText('Message archived')
      ).not.toBeInTheDocument();
    });
  }
);
