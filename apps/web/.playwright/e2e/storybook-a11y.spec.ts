import {expect, test} from '../fixtures';
import type {StoryEntry} from '../storybook';
import {
  getStoryIdentity,
  listStoryIdentitiesInSource,
  readStoryIndex,
} from '../storybook';

// A missing build is a failing test, never a skipped or empty one.
let stories: StoryEntry[] = [];
let indexError: Error | undefined;

try {
  stories = readStoryIndex();
} catch (error) {
  indexError = error as Error;
}

const requireIndex = () => {
  if (indexError) throw indexError;
};

// The per-story axe scans run in Vitest, light and dark, against source. The
// Playwright story specs load the static build, so this keeps the build in
// step with source.
test.describe('storybook a11y', () => {
  test('the built Storybook indexes exactly the stories in source', () => {
    requireIndex();
    const fromSource = listStoryIdentitiesInSource();
    const fromIndex = new Set(stories.map(getStoryIdentity));
    const missingFromBuild = [...fromSource].filter(
      (identity) => !fromIndex.has(identity)
    );
    const missingFromSource = [...fromIndex].filter(
      (identity) => !fromSource.has(identity)
    );

    expect(fromSource.size, 'story exports found in source').toBeGreaterThan(0);
    expect(
      {missingFromBuild, missingFromSource},
      'index.json and source list different stories: rebuild with `pnpm build-storybook`'
    ).toEqual({missingFromBuild: [], missingFromSource: []});
  });
});
