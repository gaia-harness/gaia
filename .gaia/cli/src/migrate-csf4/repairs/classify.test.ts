import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {classifyStoryFile} from './index.js';

const FILE = 'app/components/x/tests/index.stories.tsx';

const classify = (source: string) => classifyStoryFile(ts, source, FILE);

describe('classifyStoryFile', () => {
  test('a Template.bind named export is csf2', () => {
    const source = `import Button from '..';

export default {component: Button};

const Template = (args) => <Button {...args} />;

export const Primary = Template.bind({});
`;

    expect(classify(source)).toBe('csf2');
  });

  test('a storiesOf call is csf2', () => {
    const source = `import {storiesOf} from '@storybook/react';
import Button from '..';

storiesOf('Button', module).add('default', () => <Button />);
`;

    expect(classify(source)).toBe('csf2');
  });

  test('an export default meta is csf3', () => {
    const source = `import type {Meta, StoryObj} from '@storybook/react-vite';
import Button from '..';

const meta = {component: Button} satisfies Meta<typeof Button>;

export default meta;

export const Default: StoryObj<typeof meta> = {};
`;

    expect(classify(source)).toBe('csf3');
  });

  test('a preview.meta file importing #.storybook/preview is csf4', () => {
    const source = `import preview from '#.storybook/preview';
import Button from '..';

const meta = preview.meta({component: Button});

export const Default = meta.story({});
`;

    expect(classify(source)).toBe('csf4');
  });

  test('a preview.type<...>().meta file is csf4', () => {
    const source = `import preview from '#.storybook/preview';
import Button from '..';

type StoryArgs = {label: string};

const meta = preview.type<{args: StoryArgs}>().meta({component: Button});

export const Default = meta.story({});
`;

    expect(classify(source)).toBe('csf4');
  });

  test('a csf4 file whose preview import is relative is still csf4', () => {
    const source = `import preview from '../../.storybook/preview';
import Button from '..';

const meta = preview.meta({component: Button});

export const Default = meta.story({});
`;

    expect(classify(source)).toBe('csf4');
  });

  test('an object-literal named export beside preview.meta is unknown', () => {
    const source = `import preview from '#.storybook/preview';
import Button from '..';

const meta = preview.meta({component: Button});

export const Default = {args: {label: 'x'}} satisfies object;
`;

    expect(classify(source)).toBe('unknown');
  });

  test('a file with no preview import and no default export is unknown', () => {
    const source = `import Button from '..';

export const Default = () => <Button />;
`;

    expect(classify(source)).toBe('unknown');
  });
});
