import preview from '#.storybook/preview';
import {Separator} from '~/components/ui/separator';

const meta = preview.meta({
  component: Separator,
  parameters: {
    wrap: 'max-w-sm p-4',
  },
  title: 'Components/Ui/Separator',
});

export const Default = meta.story({
  render: () => (
    <div className="flex flex-col gap-4">
      <p className="text-sm">Above</p>
      <Separator />
      <div className="flex h-5 items-center gap-4 text-sm">
        <span>Left</span>
        <Separator orientation="vertical" />
        <span>Right</span>
      </div>
    </div>
  ),
});
