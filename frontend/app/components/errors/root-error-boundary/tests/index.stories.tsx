import stubs from 'test/stubs';
import preview from '#.storybook/preview';
import RootErrorBoundary from '..';

const meta = preview.meta({
  component: RootErrorBoundary,
  decorators: [stubs.reactRouter()],
  parameters: {
    toaster: false,
  },
  title: 'Components/Errors/RootErrorBoundary',
});

type BoundaryProps = Parameters<typeof RootErrorBoundary>[0];

const createBoundaryProps = (error: unknown) =>
  ({error, params: {}}) as unknown as BoundaryProps;

export const NotFound = meta.story({
  render: () => (
    <RootErrorBoundary
      {...createBoundaryProps({
        data: '',
        internal: true,
        status: 404,
        statusText: 'Not Found',
      })}
    />
  ),
});

const serverError = new Error('Something broke while rendering');

// Pinned so the snapshot never carries build-specific chunk paths.
serverError.stack = `Error: Something broke while rendering
    at Dashboard (app/pages/dashboard/index.tsx:42:11)
    at renderWithHooks (react-dom.development.js:15486:18)`;

export const ServerError = meta.story({
  render: () => <RootErrorBoundary {...createBoundaryProps(serverError)} />,
});

export const Unexpected = meta.story({
  render: () => <RootErrorBoundary {...createBoundaryProps('boom')} />,
});
