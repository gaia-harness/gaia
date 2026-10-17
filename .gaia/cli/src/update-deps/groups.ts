/**
 * Companion-group resolution for `gaia update-deps run`.
 *
 * The one table mapping each package to the group it moves with, so a wave
 * processes a group atomically. The update-deps skill carries no copy: it
 * reads each entry's resolved `group` from the run's output.
 *
 * Resolution rules:
 *   - Exact-name matches win first.
 *   - Glob-style prefixes (`@storybook/*`, `eslint-plugin-*`, etc.) match
 *     next, longest-prefix-first.
 *   - The `prettier` group's `eslint-config-prettier` and
 *     `eslint-plugin-prettier` exact matches MUST take precedence over the
 *     `eslint` group's broader `eslint-config-*` / `eslint-plugin-*`
 *     prefixes; that's why exact-name matches are checked first.
 *   - `msw-storybook-addon` couples to both `storybook` and `msw`; we route
 *     it to `storybook` (more specific addon scope).
 *   - `typescript` and `@types/node` are deliberately ungrouped. A compiler
 *     bump and an ambient Node type-definition bump are independent risks with
 *     independent migration guides, so pairing them would force a TS major and
 *     an `@types/node` major to move (or stall) as one.
 *   - Anything unmatched becomes `singleton:<name>`.
 */

type GroupRule = {
  /**
   * Exact package names (highest precedence). Listed packages that are not
   * outdated still count as group members when computing wave grouping.
   */
  readonly exactNames: readonly string[];
  readonly group: string;
  /** Glob prefixes ending in `*`, e.g. `@storybook/`. Matched after exact. */
  readonly prefixes?: readonly string[];
};

/**
 * Order only breaks ties: a later rule wins an exact-name conflict and an
 * earlier one an equal-length prefix tie. Exact / prefix lookups are
 * precomputed below into maps and the singleton fallback runs last.
 */
const GROUP_RULES: readonly GroupRule[] = [
  {
    exactNames: [
      '@react-router/dev',
      '@react-router/fs-routes',
      '@react-router/node',
      '@react-router/serve',
      'react-router',
    ],
    group: 'react-router',
  },
  {
    exactNames: ['@types/react', '@types/react-dom', 'react', 'react-dom'],
    group: 'react',
  },
  {
    exactNames: [
      '@tailwindcss/vite',
      'prettier-plugin-tailwindcss',
      'tailwindcss',
    ],
    group: 'tailwindcss',
  },
  {
    exactNames: [
      '@base-ui/react',
      'class-variance-authority',
      'lucide-react',
      'shadcn',
      'tw-animate-css',
    ],
    group: 'shadcn',
  },
  {
    exactNames: [
      '@vueless/storybook-dark-mode',
      'eslint-plugin-storybook',
      'msw-storybook-addon',
      'storybook',
      'storybook-react-i18next',
    ],
    group: 'storybook',
    prefixes: ['@storybook/'],
  },
  {
    exactNames: [
      '@vitest/browser-playwright',
      '@vitest/coverage-v8',
      '@vitest/eslint-plugin',
      '@vitest/ui',
      'vitest',
      'vitest-browser-react',
    ],
    group: 'vitest',
  },
  {
    exactNames: ['@playwright/test', 'playwright'],
    group: 'playwright',
  },
  // No `typescript` rule here on purpose; see the header's resolution rules.
  {
    exactNames: [
      'i18next',
      'i18next-browser-languagedetector',
      'react-i18next',
      'remix-i18next',
    ],
    group: 'i18next',
  },
  {
    // msw-storybook-addon is intentionally claimed by `storybook` above.
    exactNames: ['msw'],
    group: 'msw',
  },
  {
    exactNames: ['@vitejs/plugin-react', 'vite'],
    group: 'vite',
  },
  {
    exactNames: ['@conform-to/react', '@conform-to/zod', 'zod'],
    group: 'zod-conform',
  },
  {
    exactNames: [],
    group: 'fontawesome',
    prefixes: ['@fortawesome/'],
  },
  {
    exactNames: ['stylelint', 'stylelint-order'],
    group: 'stylelint',
    prefixes: ['stylelint-config-'],
  },
  // Prettier's eslint-config-prettier and eslint-plugin-prettier exact entries
  // beat eslint's broader prefixes through the exact index, whatever the order.
  {
    exactNames: [
      'eslint-config-prettier',
      'eslint-plugin-prettier',
      'prettier',
    ],
    group: 'prettier',
  },
  {
    exactNames: ['@eslint/compat', '@eslint/js', 'eslint'],
    group: 'eslint',
    prefixes: ['eslint-config-', 'eslint-plugin-'],
  },
];

const buildExactIndex = (
  rules: readonly GroupRule[]
): ReadonlyMap<string, string> => {
  const out = new Map<string, string>();

  for (const rule of rules) {
    for (const name of rule.exactNames) {
      // Exact-name conflicts would mean a package is in two groups; if that
      // ever happens, the later rule wins. We do not have any such overlap
      // today.
      out.set(name, rule.group);
    }
  }

  return out;
};

// A `Map` (not `Record<string, string>`) so a lookup miss types as
// `string | undefined`; a `Record` index would type as `string`, hiding the
// genuine "not in any group" case.
const EXACT_INDEX: ReadonlyMap<string, string> = buildExactIndex(GROUP_RULES);

type PrefixMatch = {
  readonly group: string;
  readonly prefix: string;
};

const buildPrefixList = (
  rules: readonly GroupRule[]
): readonly PrefixMatch[] => {
  const out: PrefixMatch[] = [];

  for (const rule of rules) {
    for (const prefix of rule.prefixes ?? []) {
      out.push({group: rule.group, prefix});
    }
  }

  // Longest prefix wins so e.g. `@storybook/` beats `@s` if both existed.
  return out.toSorted((a, b) => b.prefix.length - a.prefix.length);
};

const PREFIX_LIST: readonly PrefixMatch[] = buildPrefixList(GROUP_RULES);

/**
 * Map a package name to its companion group. Packages outside every rule
 * fall back to `singleton:<name>` so the JSON consumer can treat groups
 * uniformly.
 */
export const resolveGroup = (name: string): string => {
  const exact = EXACT_INDEX.get(name);

  if (exact !== undefined) return exact;

  for (const entry of PREFIX_LIST) {
    if (name.startsWith(entry.prefix)) return entry.group;
  }

  return `singleton:${name}`;
};

/**
 * Given a companion group name and the full set of package names present in
 * `package.json`, return all members of that group. This is used to expand
 * groups beyond what `pnpm outdated` flagged; so all siblings move together.
 *
 * Singletons (group name starts with "singleton:") always return an empty
 * array; they have no companion members to expand.
 */
export const resolveGroupMembers = (
  groupName: string,
  allPackageNames: readonly string[]
): readonly string[] => {
  if (groupName.startsWith('singleton:')) return [];

  const out: string[] = [];

  for (const pkgName of allPackageNames) {
    if (resolveGroup(pkgName) === groupName) {
      out.push(pkgName);
    }
  }

  return out;
};
