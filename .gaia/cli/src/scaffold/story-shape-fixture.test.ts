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

describe('story shape check', () => {
  test('accepts a CSF Next story whose play only drives the UI', () => {
    expect(csf4Violations(GOOD)).toEqual([]);
    expect(countTestCalls(GOOD)).toBe(1);
    expect(expectsInsidePlays(GOOD)).toEqual([]);
  });

  test('reports an expect( inside a play, however deep', () => {
    const bad = GOOD.replace(
      "await userEvent.click(canvas.getByRole('button'));",
      "await userEvent.click(canvas.getByRole('button'));\n    if (true) {\n      await expect(canvas.getByRole('region')).toBeVisible();\n    }"
    );

    expect(expectsInsidePlays(bad)).toHaveLength(1);
    expect(csf4Violations(bad).join('\n')).toContain('expect inside a play');
  });

  test('ignores an expect( that sits in a .test( body or a comment', () => {
    const withComment = GOOD.replace(
      'export const Open',
      '// play: await expect(x) is described here\nexport const Open'
    );

    expect(expectsInsidePlays(withComment)).toEqual([]);
  });

  test('reports the CSF3 shape', () => {
    const csf3 = `import type {Meta, StoryFn} from '@storybook/react-vite';
const meta: Meta = {title: 'X'};
export default meta;
export const Default: StoryFn = () => <div />;
`;
    const found = csf4Violations(csf3).join('\n');

    expect(found).toContain('not csf4: classified csf3');
    expect(found).toContain('old-format reference: StoryFn');
    expect(found).toContain('no .test( call');
  });
});
