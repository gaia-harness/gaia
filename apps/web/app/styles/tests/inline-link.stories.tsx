import preview from '#.storybook/preview';

const meta = preview.meta({
  parameters: {
    wrap: 'max-w-prose p-4',
  },
  title: 'Styles/InlineLink',
});

// The base `a` rule underlines every anchor that is not a ui component, so a
// link inside running text is told apart by more than its color.
export const Default = meta.story({
  render: () => (
    <div className="flex flex-col gap-4">
      <p>
        Read the <a href="https://example.com/docs">documentation</a> before you
        start.
      </p>
      <p className="text-muted-foreground text-sm">
        Secondary text with an{' '}
        <a href="https://example.com/terms">inline link</a> keeps its underline.
      </p>
    </div>
  ),
});
