import {expect} from 'storybook/test';
import preview from '#.storybook/preview';
import ConformFieldError from '..';

const meta = preview.meta({
  component: ConformFieldError,
  parameters: {wrap: 'p-4'},
  title: 'Components/Form/ConformFieldError',
});

export const WithError = meta.story({
  args: {
    field: {errorId: 'email-error', errors: ['required', 'Already taken']},
  },
});

WithError.test(
  'translates a validation key and shows any other message as written',
  async ({canvas}) => {
    const alert = canvas.getByRole('alert');

    await expect(alert).toHaveAttribute('id', 'email-error');
    await expect(alert).toHaveTextContent('Required');
    await expect(alert).toHaveTextContent('Already taken');
  }
);
