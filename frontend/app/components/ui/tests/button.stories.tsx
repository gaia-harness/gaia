import type {ComponentProps, MouseEvent, MouseEventHandler} from 'react';
import {Fragment} from 'react';
import {useTranslation} from 'react-i18next';
import {Link, NavLink} from 'react-router';
import {cn} from 'cn';
import {StarIcon} from 'lucide-react';
import {expect, fn, userEvent, within} from 'storybook/test';
import stubs from 'test/stubs';
import preview from '#.storybook/preview';
import {Button, buttonVariants} from '~/components/ui/button';
import {Spinner} from '~/components/ui/spinner';

// Stories whose args exceed the component's props: the link stories hand an
// onClick spy to an anchor, which Button's own onClick type would reject.
type StoryArgs = {onClick?: MouseEventHandler<HTMLElement>};

const meta = preview.type<{args: StoryArgs}>().meta({
  component: Button,
  decorators: [stubs.reactRouter({destinations: ['/target']})],
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

type LinkButtonProps = {label?: string; to?: string};

const LinkButton = ({label, to = '/'}: LinkButtonProps) => {
  const {t} = useTranslation();

  return (
    <Button
      nativeButton={false}
      render={<Link role="link" to={to} />}
      variant="outline"
    >
      {label ?? t('next')}
    </Button>
  );
};

const NavLinkButton = ({label, to = '/'}: LinkButtonProps) => {
  const {t} = useTranslation();

  return (
    <Button
      nativeButton={false}
      render={<NavLink role="link" to={to} />}
      variant="outline"
    >
      {label ?? t('next')}
    </Button>
  );
};

const ExternalLinkButton = () => {
  const {t} = useTranslation();

  return (
    <Button
      nativeButton={false}
      // eslint-disable-next-line jsx-a11y/anchor-has-content, jsx-a11y/no-redundant-roles -- Button's `render` prop supplies the anchor content, and Base UI needs the explicit role
      render={<a href="https://example.com" role="link" />}
      variant="outline"
    >
      {t('next')}
    </Button>
  );
};

const expectLinkSemantics = async (link: HTMLElement) => {
  await expect(link).toHaveAttribute('data-slot', 'button');
  await expect(link).not.toHaveAttribute('type');
  await expect(link).toHaveClass(
    ...cn(buttonVariants({variant: 'outline'})).split(' ')
  );
};

export const AsLink = meta.story({
  render: () => <LinkButton />,
});

export const AsNavLink = meta.story({
  render: () => <NavLinkButton />,
});

export const AsExternalLink = meta.story({
  render: () => <ExternalLinkButton />,
});

// The navigating behaviors run as tests, so the link stories stay axe-scanned
// in their resting state.
const expectNavigatesOnClick = async (canvasElement: HTMLElement) => {
  await userEvent.click(within(canvasElement).getByRole('link', {name: 'Go'}));
  await expect(
    await within(canvasElement).findByText('Navigated to /target')
  ).toBeVisible();
};

const expectNavigatesOnEnter = async (canvasElement: HTMLElement) => {
  await userEvent.tab();
  await expect(
    within(canvasElement).getByRole('link', {name: 'Go'})
  ).toHaveFocus();
  await userEvent.keyboard('{Enter}');
  await expect(
    await within(canvasElement).findByText('Navigated to /target')
  ).toBeVisible();
};

export const LinkNavigates = meta.story({
  render: () => <LinkButton label="Go" to="/target" />,
});

export const NavLinkNavigates = meta.story({
  render: () => <NavLinkButton label="Go" to="/target" />,
});

// The handler stops the navigation so the test never leaves the page, and
// records that Enter activated the link.
export const ExternalLinkActivatesOnEnter = meta.story({
  args: {
    onClick: fn((event: MouseEvent<HTMLElement>) => {
      event.preventDefault();
    }),
  },
  render: (args) => (
    <Button
      nativeButton={false}
      render={
        // eslint-disable-next-line jsx-a11y/anchor-has-content, jsx-a11y/no-redundant-roles -- Button's `render` prop supplies the anchor content, and Base UI needs the explicit role
        <a href="https://example.com/docs" onClick={args.onClick} role="link" />
      }
    >
      Docs
    </Button>
  ),
});

export const DisabledDoesNotFire = meta.story({
  args: {onClick: fn()},
  render: (args) => (
    <Button disabled={true} onClick={args.onClick}>
      Save
    </Button>
  ),
});

AsLink.test('renders a link with button semantics', async ({canvas}) => {
  await expectLinkSemantics(canvas.getByRole('link'));
});

AsLink.test('points at the root path', async ({canvas}) => {
  await expect(canvas.getByRole('link')).toHaveAttribute('href', '/');
});

AsNavLink.test('renders a nav link with button semantics', async ({canvas}) => {
  await expectLinkSemantics(canvas.getByRole('link'));
});

AsNavLink.test('points at the root path', async ({canvas}) => {
  await expect(canvas.getByRole('link')).toHaveAttribute('href', '/');
});

AsExternalLink.test(
  'renders an external link with button semantics',
  async ({canvas}) => {
    await expectLinkSemantics(canvas.getByRole('link'));
  }
);

AsExternalLink.test('points at the external address', async ({canvas}) => {
  await expect(canvas.getByRole('link')).toHaveAttribute(
    'href',
    'https://example.com'
  );
});

LinkNavigates.test('navigates when clicked', async ({canvasElement}) => {
  await expectNavigatesOnClick(canvasElement);
});

LinkNavigates.test('navigates on Enter', async ({canvasElement}) => {
  await expectNavigatesOnEnter(canvasElement);
});

NavLinkNavigates.test('navigates when clicked', async ({canvasElement}) => {
  await expectNavigatesOnClick(canvasElement);
});

NavLinkNavigates.test('navigates on Enter', async ({canvasElement}) => {
  await expectNavigatesOnEnter(canvasElement);
});

ExternalLinkActivatesOnEnter.test(
  'fires the click handler when Enter activates the link',
  async ({args, canvas}) => {
    await userEvent.tab();

    const link = canvas.getByRole('link', {name: 'Docs'});

    await expect(link).toHaveFocus();
    await userEvent.keyboard('{Enter}');
    await expect(link).toHaveAttribute('href', 'https://example.com/docs');
    await expect(args.onClick).toHaveBeenCalledTimes(1);
    await expect(args.onClick).toHaveBeenCalledWith(
      expect.objectContaining({type: 'click'})
    );
  }
);

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
