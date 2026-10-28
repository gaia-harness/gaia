import {expect, mocked, spyOn} from 'storybook/test';
import preview from '#.storybook/preview';
import ErrorStack from '..';

const meta = preview.meta({
  beforeEach: () => {
    const writeText = spyOn(navigator.clipboard, 'writeText');

    return () => writeText.mockRestore();
  },
  component: ErrorStack,
  parameters: {
    wrap: 'p-4',
  },
  title: 'Components/Errors/ErrorStack',
});

const stack = `Unable to do something
  SyntaxError: Unexpected token (17:33)
    at constructor (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:134713:15)
    at xv.raise (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:137030:54)
    at xv.unexpected (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:137047:18)
    at xv.parseParenAndDistinguishExpression (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:142326:125)
    at xv.parseExprAtom (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:142104:23)
    at xv.parseExprAtom (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:139480:45)
    at xv.parseExprSubscripts (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141962:78)
    at xv.parseUpdate (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141952:45)
    at xv.parseMaybeUnary (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141937:20)
    at xv.parseMaybeUnary (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141232:93)
    at xv.parseMaybeUnaryOrPrivate (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141845:63)
    at xv.parseExprOps (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141848:78)
    at xv.parseMaybeConditional (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141833:78)
    at xv.parseMaybeAssign (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141817:20)
    at xv.parseMaybeAssign (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141205:22)
    at /Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141799:41
    at xv.allowInAnd (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:142786:18)
    at xv.parseMaybeAssignAllowIn (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141799:19)
    at xv.parseVar (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:143361:105)
    at xv.parseVarStatement (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:143275:32)
    at xv.parseVarStatement (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141027:33)
    at xv.parseStatementContent (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:143074:23)
    at xv.parseStatementContent (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141050:20)
    at xv.parseStatementLike (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:143022:69)`;

export const Default = meta.story({
  render: () => (
    <ErrorStack
      className="max-h-96 max-w-360 overflow-y-auto"
      stack={stack}
      status={500}
      statusText="Server error"
    />
  ),
});

export const WithoutStatus = meta.story({
  render: () => (
    <ErrorStack className="max-h-96 max-w-360 overflow-y-auto" stack={stack} />
  ),
});

export const CopiesStack = meta.story({
  render: () => <ErrorStack stack="boom stack" />,
});

CopiesStack.test(
  'copies the stack when the button is clicked',
  async ({canvas, userEvent}) => {
    await userEvent.click(canvas.getByRole('button', {name: /copy/i}));

    await expect(navigator.clipboard.writeText).toHaveBeenCalledWith(
      'boom stack'
    );
  }
);

CopiesStack.test(
  'copies the stack when activated by keyboard',
  async ({canvas, userEvent}) => {
    const button = canvas.getByRole('button', {name: /copy/i});

    await userEvent.tab();
    await expect(button).toHaveFocus();

    await userEvent.keyboard('{Enter}');

    await expect(navigator.clipboard.writeText).toHaveBeenCalledWith(
      'boom stack'
    );
  }
);

CopiesStack.test(
  'keeps the control when the clipboard rejects',
  async ({canvas, userEvent}) => {
    mocked(navigator.clipboard.writeText).mockRejectedValue(
      new Error('clipboard denied')
    );

    await userEvent.click(canvas.getByRole('button', {name: /copy/i}));

    // A surfaced rejection would fail the run as an unhandled error, and would
    // replace the control with an error boundary.
    await expect(navigator.clipboard.writeText).toHaveBeenCalledWith(
      'boom stack'
    );
    await expect(canvas.getByRole('button', {name: /copy/i})).toBeVisible();
  }
);

CopiesStack.test('shows a copy icon on the button', async ({canvas}) => {
  const button = canvas.getByRole('button');

  // The icon is decorative: the component hides it from assistive technology,
  // so the button's accessible name comes from its label alone.
  await expect(
    button.querySelector('svg[aria-hidden="true"]')
  ).toBeInTheDocument();
});
