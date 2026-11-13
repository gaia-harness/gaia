import gaiaLint from '@gaia-harness/lint';
import {defineConfig} from 'eslint/config';
import {nodeTestExclude, nodeTestInclude} from './node-test-globs.mjs';

const lint = gaiaLint();

export default defineConfig([
  ...lint.ignores({extra: ['.gaia/**']}),
  ...lint.base,
  ...lint.react,
  ...lint.reactRouter,
  ...lint.testing,
  ...lint.storybook,
  ...lint.playwright,
  ...lint.styleHygiene,
  ...lint.guardrails,
  ...lint.betterTailwind({
    entryPoint: './app/styles/tailwind.css',
    ignore: ['dark'],
  }),
  ...lint.i18n,
  ...lint.zod,
  ...lint.prettier,
  ...lint.shadcn({ui: '~/components/ui'}),
  // These files run in Node (server modules and the vitest node project),
  // where CSS is undefined, so the rule's CSS.escape autofix would crash them.
  {
    files: ['app/**/*.server.ts?(x)', ...nodeTestInclude],
    ignores: nodeTestExclude,
    rules: {'unicorn/require-css-escape': 'off'},
  },
]);
