import {expect, within} from 'storybook/test';
import preview from '#.storybook/preview';
import {toast, Toaster} from '~/components/ui/toast';
import {expectToast} from '~/utils/tests/expect-toast';

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
      actionProps: {children: 'Undo', onClick: () => undefined},
      title: 'Message archived',
    });

    await findToast(canvasElement, 'Message archived');
  },
});

export const Loading = meta.story({
  parameters: {chromatic: {disableSnapshot: true}},
  play: async ({canvasElement}) => {
    toast.add({title: 'Uploading file', type: 'loading'});

    await findToast(canvasElement, 'Uploading file');
  },
});

// One story per type so the indexer reads each export as a story.
export const ErrorType = meta.story({
  play: async ({canvasElement}) => {
    toast.add({title: 'error toast', type: 'error'});

    await findToast(canvasElement, 'error toast');
  },
});

export const Info = meta.story({
  play: async ({canvasElement}) => {
    toast.add({title: 'info toast', type: 'info'});

    await findToast(canvasElement, 'info toast');
  },
});

export const Success = meta.story({
  play: async ({canvasElement}) => {
    toast.add({title: 'success toast', type: 'success'});

    await findToast(canvasElement, 'success toast');
  },
});

export const Warning = meta.story({
  play: async ({canvasElement}) => {
    toast.add({title: 'warning toast', type: 'warning'});

    await findToast(canvasElement, 'warning toast');
  },
});

Default.test('shows the toast title', async ({canvasElement}) => {
  await expectToast(canvasElement, 'Event created');
});

WithAction.test('shows the action button', async ({canvasElement}) => {
  await expectToast(canvasElement, 'Message archived');
  await expect(
    within(canvasElement.ownerDocument.body).getByRole('button', {
      name: 'Undo',
    })
  ).toBeVisible();
});

Loading.test('shows the loading toast', async ({canvasElement}) => {
  await expectToast(canvasElement, 'Uploading file');
});

ErrorType.test('shows the error toast', async ({canvasElement}) => {
  await expectToast(canvasElement, 'error toast');
});

Info.test('shows the info toast', async ({canvasElement}) => {
  await expectToast(canvasElement, 'info toast');
});

Success.test('shows the success toast', async ({canvasElement}) => {
  await expectToast(canvasElement, 'success toast');
});

Warning.test('shows the warning toast', async ({canvasElement}) => {
  await expectToast(canvasElement, 'warning toast');
});
