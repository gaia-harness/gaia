import AxeBuilder from '@axe-core/playwright';
import {test as base, expect} from '@playwright/test';
import {AXE_WCAG_TAGS} from '../test/axe-tags';

type AxeFixtures = {
  makeAxeBuilder: () => AxeBuilder;
};

/**
 * Extended Playwright test with an axe-core builder fixture.
 * Default tag set: WCAG 2.0/2.1 A and AA.
 */
export const test = base.extend<AxeFixtures>({
  makeAxeBuilder: async ({page}, provide) => {
    const createAxeBuilder = () =>
      new AxeBuilder({page}).withTags(AXE_WCAG_TAGS);

    await provide(createAxeBuilder);
  },
});

export {expect};
