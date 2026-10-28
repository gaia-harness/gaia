import preview from '#.storybook/preview';
import Meter from '..';

const meta = preview.meta({
  component: Meter,
  title: 'Components/Meter',
});

export const Three = meta.story({
  args: {count: 'three'},
});
