import type {ComponentProps} from 'react';
import {useTranslation} from 'react-i18next';
import {SearchIcon, SendIcon} from 'lucide-react';
import {expect, userEvent} from 'storybook/test';
import preview from '#.storybook/preview';
import {
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupInput,
  InputGroupText,
} from '~/components/ui/input-group';

const meta = preview.meta({
  component: InputGroup,
  parameters: {
    wrap: 'max-w-sm p-4',
  },
  title: 'Components/Ui/InputGroup',
});

type AddonStoryProps = {align: Align};
type Align = NonNullable<ComponentProps<typeof InputGroupAddon>['align']>;

type ButtonSize = NonNullable<ComponentProps<typeof InputGroupButton>['size']>;
type ButtonStoryProps = {size: ButtonSize};

const AddonStory = ({align}: AddonStoryProps) => {
  const {t} = useTranslation();

  return (
    <InputGroup>
      <InputGroupInput aria-label={t('email')} />
      <InputGroupAddon align={align}>
        <InputGroupText>{t('email')}</InputGroupText>
      </InputGroupAddon>
    </InputGroup>
  );
};

const ButtonStory = ({size}: ButtonStoryProps) => {
  const {t} = useTranslation();

  return (
    <InputGroup>
      <InputGroupInput aria-label={t('email')} />
      <InputGroupAddon align="inline-end">
        <InputGroupButton aria-label={t('form.submit')} size={size}>
          <SendIcon />
        </InputGroupButton>
      </InputGroupAddon>
    </InputGroup>
  );
};

export const AddonInlineStart = meta.story({
  render: () => <AddonStory align="inline-start" />,
});

export const AddonInlineEnd = meta.story({
  render: () => <AddonStory align="inline-end" />,
});

export const AddonBlockStart = meta.story({
  render: () => <AddonStory align="block-start" />,
});

export const AddonBlockEnd = meta.story({
  render: () => <AddonStory align="block-end" />,
});

export const ButtonXs = meta.story({render: () => <ButtonStory size="xs" />});

export const ButtonSm = meta.story({render: () => <ButtonStory size="sm" />});

export const ButtonIconXs = meta.story({
  render: () => <ButtonStory size="icon-xs" />,
});

export const ButtonIconSm = meta.story({
  render: () => <ButtonStory size="icon-sm" />,
});

export const Invalid = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <InputGroup>
        <InputGroupInput aria-invalid={true} aria-label={t('email')} />
        <InputGroupAddon>
          <SearchIcon />
        </InputGroupAddon>
      </InputGroup>
    );
  },
});

export const Disabled = meta.story({
  render: () => {
    const {t} = useTranslation();

    return (
      <InputGroup>
        <InputGroupInput aria-label={t('email')} disabled={true} />
        <InputGroupAddon>
          <SearchIcon />
        </InputGroupAddon>
      </InputGroup>
    );
  },
});

AddonInlineStart.test(
  'focuses the input when the addon is clicked',
  async ({canvas}) => {
    const input = canvas.getByRole('textbox', {name: 'Email'});

    await expect(input).not.toHaveFocus();

    await userEvent.click(canvas.getByText('Email'));

    await expect(input).toHaveFocus();
  }
);

ButtonXs.test(
  'keeps focus on the addon button when it is clicked',
  async ({canvas}) => {
    const button = canvas.getByRole('button', {name: 'Submit'});

    await userEvent.click(button);

    await expect(button).toHaveFocus();
    await expect(
      canvas.getByRole('textbox', {name: 'Email'})
    ).not.toHaveFocus();
  }
);
