import {describe, expect, test} from 'vitest';
import {resolveGroup, resolveGroupMembers} from './groups.js';

type GroupCase = {
  expectedGroups: Record<string, string>;
  memberChecks: {expected: unknown; group: string; packageNames: string[]}[];
  name: string;
};

describe('companion groups', () => {
  test.each(
    (
      [
        {
          expectedGroups: {'lint-staged': 'singleton:lint-staged'},
          memberChecks: [
            {
              expected: [],
              group: 'singleton:lint-staged',
              packageNames: ['lint-staged', 'prettier'],
            },
          ],
          name: 'lint-staged is an ungrouped singleton with no companions',
        },
        {
          expectedGroups: {
            '@base-ui/react': 'shadcn',
            'class-variance-authority': 'shadcn',
            'lucide-react': 'shadcn',
            shadcn: 'shadcn',
            'tw-animate-css': 'shadcn',
          },
          memberChecks: [
            {
              expected: expect.arrayContaining(['shadcn', 'lucide-react']),
              group: 'shadcn',
              packageNames: ['shadcn', 'lucide-react'],
            },
          ],
          name: 'the shadcn component layer packages move as one group',
        },
        {
          expectedGroups: {
            '@playwright/test': 'playwright',
            '@vitest/browser-playwright': 'vitest',
            playwright: 'playwright',
            vitest: 'vitest',
            'vitest-browser-react': 'vitest',
          },
          memberChecks: [],
          name: 'the Vitest browser stack moves with vitest, playwright stays its own group',
        },
        {
          expectedGroups: {
            '@playwright-testing-library/test':
              'singleton:@playwright-testing-library/test',
            '@testing-library/react': 'singleton:@testing-library/react',
          },
          memberChecks: [],
          name: 'the retired testing-library packages are no longer grouped',
        },
        {
          expectedGroups: {
            '@storybook/addon-a11y': 'storybook',
            '@storybook/addon-vitest': 'storybook',
          },
          memberChecks: [],
          name: 'the Storybook test addons fall under the @storybook/ prefix',
        },
      ] satisfies GroupCase[]
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {expectedGroups, memberChecks}) => {
    for (const [packageName, group] of Object.entries(expectedGroups)) {
      expect(resolveGroup(packageName)).toBe(group);
    }

    for (const {expected, group, packageNames} of memberChecks) {
      expect(resolveGroupMembers(group, packageNames)).toEqual(expected);
    }
  });
});
