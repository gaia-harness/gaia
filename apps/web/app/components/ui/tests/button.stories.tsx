import type {ComponentProps} from 'react';
import {Fragment} from 'react';
import {useTranslation} from 'react-i18next';
import {StarIcon} from 'lucide-react';
import {expect, fn, userEvent} from 'storybook/test';
import preview from '#.storybook/preview';
import {Button} from '~/components/ui/button';
import {Spinner} from '~/components/ui/spinner';

const meta = preview.meta({
  component: Button,
  parameters: {
    wrap: 'w-fit p-4',
  },
  title: 'Components/Ui/Button',
});

// Compile-time guard: fails when a variant or size is missing from the lists
// below, so a registry overwrite that adds one cannot leave the grid behind.
type AssertNever<T extends never> = T;
type ButtonSizeName = NonNullable<ComponentProps<typeof Button>['size']>;
type ButtonVariantName = NonNullable<ComponentProps<typeof Button>['variant']>;
// eslint-disable-next-line unused-imports/no-unused-vars -- the alias exists only to fail compilation
type UncoveredSizes = AssertNever<
  Exclude<
    ButtonSizeName,
    'default' | (typeof SIZES)[number][keyof (typeof SIZES)[number]]
  >
>;
// eslint-disable-next-line unused-imports/no-unused-vars -- the alias exists only to fail compilation
type UncoveredVariants = AssertNever<
  Exclude<ButtonVariantName, (typeof VARIANTS)[number]>
>;

const VARIANTS = [
  'default',
  'outline',
  'secondary',
  'ghost',
  'destructive',
  'link',
] as const;

// Each text size pairs with the icon-only size of the same height.
const SIZES = [
  {icon: 'icon-xs', text: 'xs'},
  {icon: 'icon-sm', text: 'sm'},
  {icon: 'icon', text: 'default'},
  {icon: 'icon-lg', text: 'lg'},
] as const;

type ButtonGridProps = {
  content?: 'icon' | 'icon-text' | 'text';
  isDisabled?: boolean;
  isInvalid?: boolean;
  isLoading?: boolean;
};

// Every variant (columns) at every size (rows), in one state.
const ButtonGrid = ({
  content = 'text',
  isDisabled = false,
  isInvalid = false,
  isLoading = false,
}: ButtonGridProps) => {
  const {t} = useTranslation();
  const label = isLoading ? t('form.submitting') : t('form.submit');

  return (
    <div className="grid grid-cols-7 items-center justify-items-start gap-x-6 gap-y-4">
      <span />
      {VARIANTS.map((variant) => (
        <span key={variant} className="text-muted-foreground text-sm">
          {variant}
        </span>
      ))}
      {SIZES.map((size) => (
        <Fragment key={size.text}>
          <span className="text-muted-foreground text-sm">
            {content === 'icon' ? size.icon : size.text}
          </span>
          {VARIANTS.map((variant) => (
            <Button
              key={variant}
              aria-invalid={isInvalid}
              aria-label={content === 'icon' ? label : undefined}
              disabled={isDisabled || isLoading}
              size={content === 'icon' ? size.icon : size.text}
              variant={variant}
            >
              {isLoading && (
                <Spinner aria-label={t('loading')} data-icon="inline-start" />
              )}
              {!isLoading && content !== 'text' && (
                <StarIcon data-icon="inline-start" />
              )}
              {content !== 'icon' && label}
            </Button>
          ))}
        </Fragment>
      ))}
    </div>
  );
};

export const Default = meta.story({render: () => <ButtonGrid />});

export const Disabled = meta.story({
  render: () => <ButtonGrid isDisabled={true} />,
});

export const Loading = meta.story({
  parameters: {
    chromatic: {disableSnapshot: true},
  },
  render: () => <ButtonGrid isLoading={true} />,
});

export const Invalid = meta.story({
  render: () => <ButtonGrid isInvalid={true} />,
});

export const Icon = meta.story({render: () => <ButtonGrid content="icon" />});

export const IconDisabled = meta.story({
  render: () => <ButtonGrid content="icon" isDisabled={true} />,
});

export const IconText = meta.story({
  render: () => <ButtonGrid content="icon-text" />,
});

export const DisabledDoesNotFire = meta.story({
  args: {onClick: fn()},
  render: (args) => (
    <Button disabled={true} onClick={args.onClick}>
      Save
    </Button>
  ),
});

DisabledDoesNotFire.test(
  'ignores a click while disabled',
  async ({args, canvas}) => {
    const button = canvas.getByRole('button', {name: 'Save'});

    await expect(button).toBeDisabled();
    // The disabled button sets pointer-events: none, which the default
    // userEvent refuses to click through.
    await userEvent.setup({pointerEventsCheck: 0}).click(button);
    await expect(args.onClick).not.toHaveBeenCalled();
  }
);
