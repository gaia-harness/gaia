import {expect} from 'storybook/test';
import preview from '#.storybook/preview';

const meta = preview.meta({
  render: () => <hr />,
  title: 'Fixtures/A11y test child opt-out',
});

export const Default = meta.story({});

Default.test('renders a separator', async ({canvas}) => {
  await expect(canvas.getByRole('separator')).toBeInTheDocument();
});

Default.test(
  'turns the accessibility check off',
  {parameters: {a11y: {disable: true}}},
  async ({canvas}) => {
    await expect(canvas.getByRole('separator')).toBeInTheDocument();
  }
);
