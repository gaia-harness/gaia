import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {readMigrationFixture} from './repairs-fixture.js';
import {capturePreCodemodFacts, restoreLeadingComment} from './index.js';

const FILE = 'app/components/x/tests/index.stories.tsx';

const COMMENTED = `// The form posts to its own route, so the story observes the submission
// through the route's own action.

import type {Meta, StoryFn} from '@storybook/react-vite';
import Form from '..';

const meta: Meta = {component: Form};

export default meta;

export const Default: StoryFn = () => <Form />;
`;

describe('capturePreCodemodFacts', () => {
  test('captures the leading comment block before the first import', () => {
    expect(capturePreCodemodFacts(ts, COMMENTED, FILE).leadingComment).toBe(
      `// The form posts to its own route, so the story observes the submission
// through the route's own action.`
    );
  });

  test('a file opening with an import has no leading comment', () => {
    const source = readMigrationFixture('error-stack.stories.tsx.csf3');

    expect(
      capturePreCodemodFacts(ts, source, FILE).leadingComment
    ).toBeUndefined();
  });

  test('captures a custom args type from Meta<StoryArgs>', () => {
    const source = readMigrationFixture('composed-form.stories.tsx.csf3');

    expect(capturePreCodemodFacts(ts, source, FILE).metaArgsType).toBe(
      'StoryArgs'
    );
  });

  test('captures a custom args type from satisfies Meta<StoryArgs>', () => {
    const source = `import type {Meta} from '@storybook/react-vite';
import Form from '..';

type StoryArgs = {onSubmit: () => void};

export default {component: Form} satisfies Meta<StoryArgs>;
`;

    expect(capturePreCodemodFacts(ts, source, FILE).metaArgsType).toBe(
      'StoryArgs'
    );
  });

  test('a Meta<typeof Component> meta has no custom args type', () => {
    const source = `import type {Meta} from '@storybook/react-vite';
import Form from '..';

const meta = {component: Form} satisfies Meta<typeof Form>;

export default meta;
`;

    expect(
      capturePreCodemodFacts(ts, source, FILE).metaArgsType
    ).toBeUndefined();
  });

  test('names each export built by a same-file factory call', () => {
    const source = readMigrationFixture('toast.stories.tsx.csf3');

    expect(capturePreCodemodFacts(ts, source, FILE).factoryExports).toEqual([
      'ErrorType',
      'Info',
      'Success',
      'Warning',
    ]);
  });
});

describe('restoreLeadingComment', () => {
  const dropped = `import preview from '#.storybook/preview';
import Form from '..';

const meta = preview.meta({component: Form});

export const Default = meta.story(() => <Form />);
`;

  test('restores a comment the codemod dropped, with its original spacing', () => {
    const restored = restoreLeadingComment(COMMENTED, dropped);

    expect(restored).toBe(
      `// The form posts to its own route, so the story observes the submission
// through the route's own action.

${dropped}`
    );
  });

  test('feeding its own output back in changes nothing', () => {
    const restored = restoreLeadingComment(COMMENTED, dropped);

    expect(restoreLeadingComment(COMMENTED, restored)).toBe(restored);
  });

  test('an original with no leading comment leaves the output alone', () => {
    const original = readMigrationFixture('error-stack.stories.tsx.csf3');

    expect(restoreLeadingComment(original, dropped)).toBe(dropped);
  });
});
