import {expect} from 'storybook/test';
import preview from '#.storybook/preview';
import Gauge from '..';

const meta = preview.meta({
  component: Gauge,
  title: 'Components/Gauge',
});

export const Half = meta.story({
  args: {level: 50},
});

Half.test('shows the level', async ({canvas}) => {
  await expect(canvas.getByRole('status')).toHaveTextContent('50');
});

Half.test('claims the wrong level', async ({canvas}) => {
  await expect(canvas.getByRole('status')).toHaveTextContent('99');
});
