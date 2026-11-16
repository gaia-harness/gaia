import type {KnipConfig} from 'knip';

export default {
  entry: ['src/**/*.test.ts'],
  // The CSF story repair tests resolve storybook from apps/web at runtime and
  // skip their indexer checks when the frontend is not installed, so the CLI
  // never declares it.
  ignoreDependencies: ['storybook'],
  project: ['src/**/*.ts', 'test-fixtures/**'],
} satisfies KnipConfig;
