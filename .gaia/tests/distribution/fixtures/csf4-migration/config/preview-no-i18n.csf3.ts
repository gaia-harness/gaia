import type {Preview} from '@storybook/react-vite';
import {mswLoader} from 'msw-storybook-addon/csf3';
import a11y from './a11y';
import {decorators} from './chromatic';
import {allModes} from './modes';
import viewport from './viewport';
import '~/styles/tailwind.css';

const preview: Preview = {
  decorators,
  loaders: [mswLoader()],
  parameters: {
    a11y,
    chromatic: {modes: allModes},
    layout: 'fullscreen',
    viewport,
  },
};

export default preview;
