import type {Page} from '@playwright/test';
import {afterEach, describe, expect, test, vi} from 'vitest';
import fs from 'node:fs';
import {loadStory} from '../.playwright/storybook';

// Every Storybook spec loads its stories through loadStory, so it must refuse
// a missing build by naming the build command. Without the check a spec
// navigates to the empty story server and times out with no cause named, which
// reads as a flake under load.

const MISSING_BUILD_MESSAGE = /run `pnpm build-storybook` before `pnpm pw`/;

const createPageStub = () => {
  const goto = vi.fn();
  const page = {goto, route: vi.fn()} as unknown as Page;

  return {goto, page};
};

const hideStorybookBuild = () => {
  const realExistsSync = fs.existsSync;

  vi.spyOn(fs, 'existsSync').mockImplementation((candidate) =>
    String(candidate).endsWith('storybook-static/index.json') ?
      false
    : realExistsSync(candidate)
  );
};

afterEach(() => {
  vi.restoreAllMocks();
});

describe('Storybook build guard', () => {
  test('loadStory refuses a missing build before navigating', async () => {
    hideStorybookBuild();
    const {goto, page} = createPageStub();

    await expect(
      loadStory(page, 'components-themeswitch--default', 'light')
    ).rejects.toThrow(MISSING_BUILD_MESSAGE);
    expect(goto).not.toHaveBeenCalled();
  });
});
