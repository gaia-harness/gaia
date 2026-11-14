import gaiaLint from '@gaia-harness/lint';
import {defineConfig} from 'eslint/config';
import {nodeTestExclude, nodeTestInclude} from './node-test-globs.mjs';

// The preset already exempts **/*.server.ts?(x) files; a React Router
// .server directory (app/sessions.server/) needs its own glob.
const lint = gaiaLint({
  nodeFiles: {
    exclude: nodeTestExclude,
    include: [...nodeTestInclude, 'app/**/*.server/**/*.ts?(x)'],
  },
});

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
]);
