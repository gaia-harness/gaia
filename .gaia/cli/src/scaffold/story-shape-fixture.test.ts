import {describe, expect, test} from 'vitest';
import {
  countTestCalls,
  csf4Violations,
  expectsInsidePlays,
} from './story-shape-fixture.js';

const GOOD = `import {expect} from 'storybook/test';
import preview from '#.storybook/preview';
import Foo from '..';

const meta = preview.meta({component: Foo});

export const Default = meta.story({render: () => <Foo />});

export const Open = Default.extend({
  play: async ({canvas, userEvent}) => {
    await userEvent.click(canvas.getByRole('button'));
  },
});

Open.test('shows the panel', async ({canvas}) => {
  await expect(canvas.getByRole('region')).toBeVisible();
});
`;

const WITH_DEEP_EXPECT = GOOD.replace(
  "await userEvent.click(canvas.getByRole('button'));",
  "await userEvent.click(canvas.getByRole('button'));\n    if (true) {\n      await expect(canvas.getByRole('region')).toBeVisible();\n    }"
);

const WITH_COMMENT = GOOD.replace(
  'export const Open',
  '// play: await expect(x) is described here\nexport const Open'
);

const CSF3 = `import type {Meta, StoryFn} from '@storybook/react-vite';
const meta: Meta = {title: 'X'};
export default meta;
export const Default: StoryFn = () => <div />;
`;

describe('story shape check accepts a CSF Next story and reports each violation', () => {
  test.each([
    {
      name: 'accepts a CSF Next story whose play only drives the UI',
      playExpects: 0,
      source: GOOD,
      testCalls: 1,
      violations: [/^$/u],
    },
    {
      name: 'reports an expect( inside a play, however deep',
      playExpects: 1,
      source: WITH_DEEP_EXPECT,
      testCalls: 1,
      violations: [/expect inside a play/u],
    },
    {
      name: 'ignores an expect( that sits in a .test( body or a comment',
      playExpects: 0,
      source: WITH_COMMENT,
      testCalls: 1,
      violations: [/^$/u],
    },
    {
      name: 'reports the CSF3 shape',
      playExpects: 0,
      source: CSF3,
      testCalls: 0,
      violations: [
        /not csf4: classified csf3/u,
        /old-format reference: StoryFn/u,
        /no \.test\( call/u,
      ],
    },
  ])('$name', ({playExpects, source, testCalls, violations}) => {
    expect(expectsInsidePlays(source)).toHaveLength(playExpects);
    expect(countTestCalls(source)).toBe(testCalls);

    for (const pattern of violations) {
      expect(csf4Violations(source).join('\n')).toMatch(pattern);
    }
  });
});
