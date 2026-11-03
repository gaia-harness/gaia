import {describe, expect, test} from 'vitest';
import path from 'node:path';
import viteConfig from '../vite.config';

// Mirrors how the watcher reads `server.watch.ignored`: a RegExp is tested
// against the absolute path, a function is called with it, and a string is a
// glob. Node's glob matcher is stricter than the watcher's about a trailing
// `**`, so a string entry here may read as not ignored when the watcher would
// ignore it: the safe direction, since it fails this test rather than passing.
const isIgnored = (file: string): boolean => {
  const ignored = viteConfig.server?.watch?.ignored;

  return (Array.isArray(ignored) ? ignored : [ignored]).some((matcher) => {
    if (matcher instanceof RegExp) return matcher.test(file);
    if (typeof matcher === 'function') return matcher(file);
    if (typeof matcher === 'string') return path.matchesGlob(file, matcher);

    return false;
  });
};

describe('vite dev server watcher', () => {
  test('ignores Playwright output, where trace .html files would reload every page', () => {
    expect(isIgnored(path.resolve('.playwright/output'))).toBe(true);
    expect(
      isIgnored(
        path.resolve(
          '.playwright/output/.playwright-artifacts-0/traces/resources/page.html'
        )
      )
    ).toBe(true);
  });

  test('still watches app source and the Playwright specs', () => {
    expect(isIgnored(path.resolve('app/root.tsx'))).toBe(false);
    expect(isIgnored(path.resolve('.playwright/e2e/home-a11y.spec.ts'))).toBe(
      false
    );
  });
});
