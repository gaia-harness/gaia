import {describe, expect, test} from 'vitest';
import a11y from '../.storybook/a11y';
import * as fixtureStories from './fixtures/a11y-test-child-opt-out.stories';
import {resolveStoryA11yOptOuts} from './story-a11y-opt-outs';

describe('story a11y opt-outs over a fixture story', () => {
  test('a test child that disables a11y is opted out while its story is not', () => {
    const optOuts = resolveStoryA11yOptOuts({fixture: fixtureStories}, a11y);

    expect(optOuts).toEqual([
      {
        id: 'fixtures-a11y-test-child-opt-out--default',
        isOptedOut: false,
      },
      {
        id: 'fixtures-a11y-test-child-opt-out--default:renders-a-separator',
        isOptedOut: false,
      },
      {
        id: 'fixtures-a11y-test-child-opt-out--default:turns-the-accessibility-check-off',
        isOptedOut: true,
      },
    ]);
  });
});
