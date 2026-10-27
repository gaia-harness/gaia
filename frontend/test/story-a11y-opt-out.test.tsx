import {describe, expect, test} from 'vitest';
import a11y from '../.storybook/a11y';
import {resolveStoryA11yOptOuts} from './story-a11y-opt-outs';

// A story's light-theme axe check runs only in the Vitest storybook project,
// under addon-a11y; the Playwright scan covers dark. addon-a11y hands axe three
// per-story inputs: `a11y.context`, `a11y.config` and `a11y.options`. A story
// or a `.test()` child is opted out when any of them differs from the shared
// defaults in `.storybook/a11y.ts` (a narrower scope, a disabled rule, a
// different tag set), when `a11y.test` is not 'error', when `a11y.disable` is
// set, when the `a11y.manual` global is on, or when the `test` tag is lost to a
// `!test` tag. An opt-out needs its id and a reason in this map.
const A11Y_OPT_OUT_REASONS: Record<string, string> = {};

const storyModules = import.meta.glob<Record<string, unknown>>(
  '../app/**/*.stories.tsx',
  {eager: true}
);

describe('story a11y opt-outs', () => {
  test('every story and test fails on an axe violation unless its opt-out is recorded', () => {
    const storyOptOuts = resolveStoryA11yOptOuts(storyModules, a11y);

    expect(storyOptOuts).not.toHaveLength(0);
    expect(
      storyOptOuts.filter(({id}) => id.includes('--unnamed-story'))
    ).toEqual([]);

    const unrecorded = storyOptOuts.filter(
      ({id, isOptedOut}) => isOptedOut && !(id in A11Y_OPT_OUT_REASONS)
    );

    expect(unrecorded).toEqual([]);
  });
});
