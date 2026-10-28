// An old-format (CSF3) story file: the story extractor refuses it with exit 8
// and names the migration command. It sits outside frontend/app/, so
// Storybook never loads it.
import type {Meta, StoryObj} from '@storybook/react-vite';

const Marker = ({text}: {text: string}) => <p>{text}</p>;

const meta = {
  args: {text: 'csf3 marker'},
  component: Marker,
  title: 'Internal/CSF3 Old Format',
} satisfies Meta<typeof Marker>;

export default meta;

type Story = StoryObj<typeof meta>;

export const WithPlay: Story = {
  play: async ({canvasElement}) => {
    canvasElement.setAttribute('data-played', 'csf3');
  },
};
