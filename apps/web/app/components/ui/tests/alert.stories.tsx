import {InfoIcon} from 'lucide-react';
import preview from '#.storybook/preview';
import {Alert, AlertDescription, AlertTitle} from '~/components/ui/alert';

const meta = preview.meta({
  component: Alert,
  parameters: {
    wrap: 'max-w-md p-4',
  },
  title: 'Components/Ui/Alert',
});

export const Default = meta.story({
  render: () => (
    <Alert>
      <InfoIcon />
      <AlertTitle>Heads up</AlertTitle>
      <AlertDescription>You can add components to your app.</AlertDescription>
    </Alert>
  ),
});

export const Destructive = meta.story({
  render: () => (
    <Alert variant="destructive">
      <InfoIcon />
      <AlertTitle>Something went wrong</AlertTitle>
      <AlertDescription>Your session has expired.</AlertDescription>
    </Alert>
  ),
});
