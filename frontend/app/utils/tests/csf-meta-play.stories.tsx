import {expect} from 'storybook/test';
import preview from '#.storybook/preview';

type MarkerProps = {text: string};

const Marker = ({text}: MarkerProps) => <p>{text}</p>;

// Fixture for the test-identity extractor: a play on the meta is inherited by
// every story in the file, so a render-only story cannot share a file with it.
const meta = preview.meta({
  args: {text: 'meta play marker'},
  component: Marker,
  parameters: {chromatic: {disableSnapshot: true}},
  play: async ({canvasElement}) => {
    canvasElement.dataset.played = 'meta play';
  },
  title: 'Internal/CSF Meta Play',
});

export const InheritsMetaPlay = meta.story({});

export const InheritsMetaPlayWithTest = meta.story({});

InheritsMetaPlayWithTest.test(
  'runs the meta play first',
  async ({canvasElement}) => {
    await expect(canvasElement).toHaveAttribute('data-played', 'meta play');
  }
);
