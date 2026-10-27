// A CSF4 story file with two tests on one story: the extractor emits the base
// story plus each test. It sits outside frontend/app/, so Storybook never
// loads it.
import preview from '#.storybook/preview';
import {expect} from 'storybook/test';

const Marker = ({text}: {text: string}) => <p>{text}</p>;

const meta = preview.meta({
  args: {text: 'csf4 marker'},
  component: Marker,
  title: 'Internal/CSF4 With Tests',
});

export const Default = meta.story({});

Default.test('shows the marker', async ({canvas}) => {
  await expect(canvas.getByText('csf4 marker')).toBeTruthy();
});

Default.test('hides nothing else', async ({canvas}) => {
  await expect(canvas.queryByText('other')).toBeNull();
});
