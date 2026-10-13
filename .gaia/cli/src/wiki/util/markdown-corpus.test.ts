import {describe, expect, test} from 'vitest';
import {
  GENERATED_CONTENT_EXEMPT_PATHS,
  isGeneratedContentExempt,
  isWikiScanExempt,
  WIKI_SCAN_EXEMPT_PREFIXES,
} from './markdown-corpus.js';

describe('the shared wiki exemption vocabulary', () => {
  test('the base tier matches a directory by prefix', () => {
    expect(isWikiScanExempt('wiki/meta/lint-report.md')).toBe(true);
    expect(isWikiScanExempt('wiki/concepts/Design System.md')).toBe(false);
  });

  test('the base tier holds only the exemption every scan shares', () => {
    expect([...WIKI_SCAN_EXEMPT_PREFIXES]).toEqual(['wiki/meta/']);
  });

  // The two tiers are separate because their warrants are, so neither
  // predicate may answer for the other: a scan that takes the base must not
  // pick up the generated-content pages through it.
  test('the base tier does not carry the generated-content pages', () => {
    expect(isWikiScanExempt('wiki/log.md')).toBe(false);
  });

  test('the generated-content tier matches its page exactly', () => {
    expect(isGeneratedContentExempt('wiki/log.md')).toBe(true);
    expect([...GENERATED_CONTENT_EXEMPT_PATHS]).toEqual(['wiki/log.md']);
  });

  // Exact, not prefix: a prefix would also swallow any page whose path merely
  // starts with the exempt one.
  test('the generated-content tier does not match a page that merely starts with it', () => {
    expect(isGeneratedContentExempt('wiki/log.md-archive.md')).toBe(false);
  });
});
