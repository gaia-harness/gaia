import type {KnipConfig} from 'knip';

export default {
  entry: ['src/**/*.test.ts'],
  // The CSF repair suite resolves storybook from apps/web at runtime and skips
  // itself when the frontend is not installed, so the CLI never declares it.
  ignoreDependencies: ['storybook'],
  project: ['src/**/*.ts', 'test-fixtures/**'],
} satisfies KnipConfig;
