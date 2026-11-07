import {describe, expect, test} from 'vitest';
import {createRequire} from 'node:module';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import vitestConfig from '../vitest.config.ts';

// Vitest resolves each `--changed` file to an absolute path and tests it
// against the triggers with its own picomatch and `{dot: true}`. picomatch is
// Vitest's dependency, not this package's, so it is loaded from Vitest's
// install: another glob matcher can disagree with it.
const requireFromVitest = createRequire(
  fileURLToPath(import.meta.resolve('vitest/package.json'))
);
const picomatch = requireFromVitest('picomatch') as (
  patterns: string[],
  options: {dot: boolean}
) => (filePath: string) => boolean;

const webRoot = path.resolve(import.meta.dirname, '..');
const triggers = vitestConfig.test?.forceRerunTriggers ?? [];
const isForceRerunTrigger = picomatch(triggers, {dot: true});

// Read from the projects so a setup file added there without a trigger fails.
const projectSetupFiles = (vitestConfig.test?.projects ?? []).flatMap(
  (project) =>
    typeof project === 'object' && 'test' in project ?
      [project.test?.setupFiles ?? []].flat()
    : []
);

describe('forceRerunTriggers', () => {
  test('the setup files are read from the projects', () => {
    expect(projectSetupFiles.length).toBeGreaterThan(0);
  });

  test.each([
    'package.json',
    'vitest.config.ts',
    'vite.config.ts',
    '.storybook/preview.ts',
    '.storybook/vite.config.ts',
    ...projectSetupFiles,
  ])('a change to %s reruns the whole suite', (file) => {
    expect(isForceRerunTrigger(path.join(webRoot, file))).toBe(true);
  });

  test('a change to an application module reruns only its dependents', () => {
    expect(isForceRerunTrigger(path.join(webRoot, 'app/root.tsx'))).toBe(false);
  });
});
