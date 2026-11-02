import type {ReactRenderer} from '@storybook/react-vite';
import type {DecoratorFunction} from 'storybook/internal/types';
import State from '~/state';

const decorator = (): DecoratorFunction<ReactRenderer> => (Story) => (
  <State>
    <Story />
  </State>
);

export default decorator;
