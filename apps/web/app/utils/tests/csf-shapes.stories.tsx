import {expect} from 'storybook/test';
import preview from '#.storybook/preview';

type MarkerProps = {text: string};

const Marker = ({text}: MarkerProps) => <p>{text}</p>;

// Fixture for the test-identity extractor: one story per CSF4 shape whose
// test names it must reproduce. A play only marks the canvas; the tests assert
// the marker and that the play ran first.
const meta = preview.meta({
  args: {text: 'default marker'},
  component: Marker,
  parameters: {chromatic: {disableSnapshot: true}},
  title: 'Internal/CSF Shapes',
});

export const PlayWithTests = meta.story({
  args: {text: 'play marker'},
  play: async ({canvasElement}) => {
    canvasElement.dataset.played = 'play with tests';
  },
});

PlayWithTests.test('shows the marker', async ({canvas}) => {
  await expect(canvas.getByText('play marker')).toBeVisible();
});

PlayWithTests.test('runs the play first', async ({canvasElement}) => {
  await expect(canvasElement).toHaveAttribute('data-played', 'play with tests');
});

export const RenderWithTest = meta.story({
  args: {text: 'render marker'},
});

RenderWithTest.test('shows the marker', async ({canvas}) => {
  await expect(canvas.getByText('render marker')).toBeVisible();
});

export const PlayOnly = meta.story({
  args: {text: 'play only marker'},
  play: async ({canvasElement}) => {
    canvasElement.dataset.played = 'play only';
  },
});

export const RenderOnly = meta.story({
  args: {text: 'render only marker'},
});

export const ExtendedPlay = PlayWithTests.extend({
  args: {text: 'extended marker'},
});

export const NamedSource = meta.story({
  args: {text: 'named marker'},
  name: 'Custom Display Name',
  play: async ({canvasElement}) => {
    canvasElement.dataset.played = 'named source';
  },
});

export const ExtendedNamed = NamedSource.extend({
  args: {text: 'extended named marker'},
});
