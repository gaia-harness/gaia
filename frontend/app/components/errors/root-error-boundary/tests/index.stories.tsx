import type {Meta, StoryFn} from '@storybook/react-vite';
import stubs from 'test/stubs';
import RootErrorBoundary from '..';

const meta: Meta = {
  component: RootErrorBoundary,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
    toaster: false,
  },
  title: 'Components/Errors/RootErrorBoundary',
};

export default meta;

type BoundaryProps = Parameters<typeof RootErrorBoundary>[0];

const createBoundaryProps = (error: unknown) =>
  ({error, params: {}}) as unknown as BoundaryProps;

export const NotFound: StoryFn = () => (
  <RootErrorBoundary
    {...createBoundaryProps({
      data: '',
      internal: true,
      status: 404,
      statusText: 'Not Found',
    })}
  />
);

const serverError = new Error('Something broke while rendering');

// Pinned so the snapshot never carries build-specific chunk paths.
serverError.stack = `Error: Something broke while rendering
    at Dashboard (app/pages/dashboard/index.tsx:42:11)
    at renderWithHooks (react-dom.development.js:15486:18)`;

export const ServerError: StoryFn = () => (
  <RootErrorBoundary {...createBoundaryProps(serverError)} />
);

export const Unexpected: StoryFn = () => (
  <RootErrorBoundary {...createBoundaryProps('boom')} />
);
