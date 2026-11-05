import {AXE_WCAG_TAGS} from '../test/axe-tags';

// Any impact fails here, in both the Vitest `storybook` and `storybook-dark`
// projects; the Playwright page scans fail only critical and serious. `region`
// is off because a story renders a fragment outside the page landmarks. Kept
// out of preview.ts so the a11y opt-out guard can resolve story parameters
// without importing the preview's stylesheet.
const a11y = {
  config: {rules: [{enabled: false, id: 'region'}]},
  options: {
    runOnly: {
      type: 'tag',
      values: AXE_WCAG_TAGS,
    } as const,
  },
  test: 'error' as const,
};

export default a11y;
